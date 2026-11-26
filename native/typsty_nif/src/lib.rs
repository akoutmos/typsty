//! The NIF that renders Typst documents inside the BEAM, with `typsty_core`.
//!
//! A render doesn't hold a scheduler while Typst works: `start_render` checks the arguments
//! and returns a job right away, and the render runs on a thread of its own (see
//! `typsty_core::isolate`). Its result is sent to the process that started it as
//! `{reference, result}`. The process cancels a render it stops waiting for with
//! `cancel_render`, and a render whose job is garbage collected (because the process exited)
//! is cancelled too.

mod value;

use rustler::env::SavedTerm;
use rustler::{
    Atom, Binary, Encoder, Env, LocalPid, NewBinary, NifMap, NifStruct, NifUnitEnum, OwnedEnv,
    ResourceArc, Term,
};
use typsty_core::isolate::{self, Interrupted, Phase, Ticket};
use typsty_core::{render, FontSettings, Format, Output, PrepareError, RenderJob, Rendered};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid,
        typst,
        crashed,
        queued,
        running,
        finished,
        abandoned,
    }
}

#[derive(NifMap)]
struct FontOptions {
    font_paths: Vec<String>,
    system_fonts: bool,
    embedded_fonts: bool,
}

impl FontOptions {
    fn settings(self) -> FontSettings {
        FontSettings::new(self.font_paths, self.system_fonts, self.embedded_fonts)
    }
}

#[derive(NifMap)]
struct RenderOptions {
    format: Atom,
    root: Option<String>,
    package_paths: Vec<String>,
    fonts: FontOptions,
    ppi: f64,
    pdf_standards: Vec<String>,
    /// How many renders may run at once, counting renders that are being cancelled.
    max_running: usize,
}

#[derive(NifMap)]
struct FormatOptions {
    line_width: usize,
    indent_width: usize,
    wrap_text: bool,
}

#[derive(NifUnitEnum)]
enum Severity {
    Error,
    Warning,
}

#[derive(NifStruct)]
#[module = "Typsty.Diagnostic"]
struct Diagnostic {
    severity: Severity,
    message: String,
    hints: Vec<String>,
    file: Option<String>,
    line: Option<usize>,
    column: Option<usize>,
    trace: Vec<TracePoint>,
}

#[derive(NifMap)]
struct TracePoint {
    message: String,
    file: Option<String>,
    line: Option<usize>,
    column: Option<usize>,
}

impl From<typsty_core::Diagnostic> for Diagnostic {
    fn from(diagnostic: typsty_core::Diagnostic) -> Self {
        Self {
            severity: match diagnostic.severity {
                typsty_core::Severity::Error => Severity::Error,
                typsty_core::Severity::Warning => Severity::Warning,
            },
            message: diagnostic.message,
            hints: diagnostic.hints,
            file: diagnostic.file,
            line: diagnostic.line,
            column: diagnostic.column,
            trace: diagnostic
                .trace
                .into_iter()
                .map(|point| TracePoint {
                    message: point.message,
                    file: point.file,
                    line: point.line,
                    column: point.column,
                })
                .collect(),
        }
    }
}

fn diagnostics(diagnostics: Vec<typsty_core::Diagnostic>) -> Vec<Diagnostic> {
    diagnostics.into_iter().map(Diagnostic::from).collect()
}

/// A render that was started, which `cancel_render` gives up on. Dropping it (when the
/// process that started the render exits) gives up on the render too.
struct Job(Ticket);

#[rustler::resource_impl]
impl rustler::Resource for Job {}

impl Drop for Job {
    fn drop(&mut self) {
        self.0.abandon();
    }
}

/// Starts compiling and exporting a template, and returns `{:ok, job}` right away. Returns
/// `{:error, :invalid, message}` when the arguments are invalid, `{:error, :typst,
/// diagnostics}` when they go over one of Typsty's limits, and `{:error, :crashed, message}`
/// when the render's thread can't be started.
///
/// The result is sent to the calling process as `{reference, result}`, where the result is
/// `{:ok, output, warnings}` (the output is a binary for PDF, and a list of binaries, one per
/// page, for PNG and SVG), `{:error, :typst, diagnostics}` when Typst fails, or
/// `{:error, :crashed, message}` when the render ends without a result.
///
/// Checking the arguments and copying the files takes a little while for large ones, so this
/// runs on a dirty scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn start_render<'a>(
    env: Env<'a>,
    reference: Term<'a>,
    template: String,
    assigns: Term<'a>,
    files: Vec<(String, Binary<'a>)>,
    options: RenderOptions,
) -> Term<'a> {
    let invalid = |message: String| (atoms::error(), atoms::invalid(), message).encode(env);

    let format = match options
        .format
        .to_term(env)
        .atom_to_string()
        .ok()
        .and_then(|name| Format::from_name(&name))
    {
        Some(format) => format,
        None => return invalid("unknown format".into()),
    };

    let assigns = match value::to_dict(assigns) {
        Ok(assigns) => assigns,
        Err(message) => return invalid(message),
    };

    let job = RenderJob {
        template,
        assigns,
        files: files
            .into_iter()
            .map(|(path, bytes)| (path, bytes.as_slice().to_vec()))
            .collect(),
        format,
        root: options.root,
        package_paths: options.package_paths,
        fonts: options.fonts.settings(),
        ppi: options.ppi,
        pdf_standards: options.pdf_standards,
    };

    let job = match job.prepare() {
        Ok(job) => job,
        Err(PrepareError::Invalid(message)) => return invalid(message),
        Err(PrepareError::Refused(message)) => {
            let errors = diagnostics(vec![typsty_core::Diagnostic::error(message)]);
            return (atoms::error(), atoms::typst(), errors).encode(env);
        }
    };

    // The result is encoded on the render's thread, before it's handed over, so that
    // handing it over only takes sending it. Another copy of the reference is kept for
    // reporting a render that ends without a result
    let message = Message::new(reference);
    let failure = Message::new(reference);
    let pid = env.pid();

    let started = isolate::start(
        options.max_running,
        move |cancellation| {
            let result = job.render(cancellation);
            message.encode(|env| encode_result(env, result))
        },
        move |result| match result {
            Ok(message) => message.send(&pid),
            Err(interrupted) => failure
                .encode(|env| encode_interrupted(env, interrupted))
                .send(&pid),
        },
    );

    match started {
        Ok(ticket) => (atoms::ok(), ResourceArc::new(Job(ticket))).encode(env),
        Err(message) => (atoms::error(), atoms::crashed(), message).encode(env),
    }
}

/// A message for the process that started a render, built in an environment of its own so
/// that it can be sent from the render's thread.
struct Message {
    env: OwnedEnv,
    reference: SavedTerm,
    term: Option<SavedTerm>,
}

impl Message {
    fn new(reference: Term) -> Self {
        let env = OwnedEnv::new();
        let reference = env.save(reference);

        Self {
            env,
            reference,
            term: None,
        }
    }

    /// Builds the message `{reference, result}`.
    fn encode(mut self, result: impl for<'a> FnOnce(Env<'a>) -> Term<'a>) -> Self {
        let term = self.env.run(|env| {
            let message = (self.reference.load(env), result(env)).encode(env);
            self.env.save(message)
        });

        self.term = Some(term);
        self
    }

    fn send(mut self, pid: &LocalPid) {
        if let Some(term) = self.term.take() {
            // The process may have exited, which is fine
            let _ = self.env.send_and_clear(pid, |env| term.load(env));
        }
    }
}

fn encode_result(env: Env, result: Result<Rendered, Vec<typsty_core::Diagnostic>>) -> Term {
    match result {
        Ok((output, warnings)) => {
            let output = encode_output(env, output);
            (atoms::ok(), output, diagnostics(warnings)).encode(env)
        }
        Err(errors) => (atoms::error(), atoms::typst(), diagnostics(errors)).encode(env),
    }
}

/// A render that ended without a result. Typsty stopping it is reported like Typst's errors.
fn encode_interrupted(env: Env, interrupted: Interrupted) -> Term {
    match interrupted {
        Interrupted::Stopped(message) => (
            atoms::error(),
            atoms::typst(),
            diagnostics(vec![typsty_core::Diagnostic::error(message)]),
        )
            .encode(env),
        other => (atoms::error(), atoms::crashed(), other.message()).encode(env),
    }
}

fn encode_output(env: Env, output: Output) -> Term {
    match output {
        Output::Pdf(bytes) => binary(env, &bytes),
        Output::Pages(pages) => pages
            .iter()
            .map(|page| binary(env, page))
            .collect::<Vec<_>>()
            .encode(env),
    }
}

fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = NewBinary::new(env, bytes.len());
    binary.as_mut_slice().copy_from_slice(bytes);
    Binary::from(binary).encode(env)
}

/// Gives up on a render: a render that's waiting to start never starts, and a running one is
/// cancelled, and its result isn't sent. Returns the phase the render was in: `:queued`,
/// `:running`, `:finished` (its result was sent) or `:abandoned`.
///
/// The render's thread may be sending its result, which only takes a moment, so this runs on
/// a dirty scheduler rather than wait on a normal one.
#[rustler::nif(schedule = "DirtyCpu")]
fn cancel_render(job: ResourceArc<Job>) -> Atom {
    match job.0.abandon() {
        Phase::Queued => atoms::queued(),
        Phase::Running => atoms::running(),
        Phase::Finished => atoms::finished(),
        Phase::Abandoned => atoms::abandoned(),
    }
}

/// Checks a template's syntax. Returns the syntax errors, which is an empty list for a valid
/// template.
#[rustler::nif(schedule = "DirtyCpu")]
fn syntax_errors(template: String) -> Vec<Diagnostic> {
    diagnostics(render::syntax_errors(template))
}

/// Checks a component's source: its syntax, and that it only defines things and doesn't read
/// `sys.inputs`. Returns the problems, which is an empty list for a valid component.
#[rustler::nif(schedule = "DirtyCpu")]
fn component_errors(source: String) -> Vec<Diagnostic> {
    diagnostics(render::component_errors(source))
}

/// The paths a component reads files from, written as strings, as `{path, line, column}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn file_paths(source: String) -> Vec<(String, usize, usize)> {
    render::file_paths(source)
}

/// Formats a template with typstyle. Returns `{:error, diagnostics}` when the template has
/// syntax errors, since it can't be formatted then.
#[rustler::nif(schedule = "DirtyCpu")]
fn format<'a>(env: Env<'a>, template: String, options: FormatOptions) -> Term<'a> {
    let formatted = render::format(
        template,
        options.line_width,
        options.indent_width,
        options.wrap_text,
    );

    match formatted {
        Ok(formatted) => (atoms::ok(), formatted).encode(env),
        Err(errors) => (atoms::error(), diagnostics(errors)).encode(env),
    }
}

/// The packages a Typst file imports or includes, such as `"@preview/oxifmt:1.0.0"`.
#[rustler::nif(schedule = "DirtyCpu")]
fn package_imports(text: String) -> Vec<String> {
    render::package_imports(text)
}

/// Scans for fonts (caching them for later renders) and returns the font families found.
#[rustler::nif(schedule = "DirtyIo")]
fn font_families(options: FontOptions) -> Vec<String> {
    render::font_families(&options.settings())
}

/// The number of renders running, including renders that were given up on and are still
/// being cancelled.
#[rustler::nif]
fn running_renders() -> usize {
    isolate::running_renders()
}

/// The version of the Typst compiler, such as "0.15.1".
#[rustler::nif]
fn typst_version() -> String {
    typsty_core::typst_version()
}

fn load(_env: Env, _info: Term) -> bool {
    // Inside the BEAM, files that are unsafe to decode are refused (see `typsty_core::checks`)
    typsty_core::init(typsty_core::Config { isolated: false });
    true
}

rustler::init!("Elixir.Typsty.Native", load = load);
