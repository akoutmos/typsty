//! The NIF that renders Typst documents inside the BEAM, with `typsty_core`.
//!
//! Terms are decoded and encoded on the NIF's own thread, and everything Typst does runs on
//! a separate thread with a large stack (see `typsty_core::isolate`).

mod value;

use std::time::Duration;

use rustler::{Atom, Binary, Encoder, Env, NewBinary, NifMap, NifStruct, NifUnitEnum, Term};
use typsty_core::{render, Failure, FontSettings, Format, Output, RenderJob};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        pdf,
        png,
        svg,
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
    /// In milliseconds, or `nil` to wait for as long as the render takes.
    timeout: Option<u64>,
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

/// Compiles a template and exports it.
///
/// Returns `{:ok, output, warnings}`, where the output is a binary for PDF and a list of
/// binaries (one per page) for PNG and SVG, `{:error, diagnostics}` when Typst fails, or
/// `{:error, message}` when the arguments are invalid.
#[rustler::nif(schedule = "DirtyCpu")]
fn render<'a>(
    env: Env<'a>,
    template: String,
    variables: Term<'a>,
    files: Vec<(String, Binary<'a>)>,
    options: RenderOptions,
) -> Term<'a> {
    let format = if options.format == atoms::pdf() {
        Format::Pdf
    } else if options.format == atoms::png() {
        Format::Png
    } else if options.format == atoms::svg() {
        Format::Svg
    } else {
        return (atoms::error(), "unknown format").encode(env);
    };

    let variables = match value::to_dict(variables) {
        Ok(variables) => variables,
        Err(message) => return (atoms::error(), message).encode(env),
    };

    let job = RenderJob {
        template,
        variables,
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

    let timeout = options.timeout.map(Duration::from_millis);
    let result = job
        .render(timeout, Some(options.max_running))
        .unwrap_or_else(|failure| {
            Err(Failure::Diagnostics(vec![typsty_core::Diagnostic::error(
                failure.message(),
            )]))
        });

    match result {
        Ok((output, warnings)) => {
            let output = encode_output(env, output);
            (atoms::ok(), output, diagnostics(warnings)).encode(env)
        }
        Err(Failure::Invalid(message)) => (atoms::error(), message).encode(env),
        Err(Failure::Diagnostics(errors)) => (atoms::error(), diagnostics(errors)).encode(env),
    }
}

fn encode_output<'a>(env: Env<'a>, output: Output) -> Term<'a> {
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

/// Checks a template's syntax. Returns the syntax errors, which is an empty list for a valid
/// template.
#[rustler::nif(schedule = "DirtyCpu")]
fn syntax_errors(template: String) -> Vec<Diagnostic> {
    diagnostics(render::syntax_errors(template))
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

/// Scans for fonts (caching them for later renders) and returns the font families found.
#[rustler::nif(schedule = "DirtyIo")]
fn font_families(options: FontOptions) -> Vec<String> {
    render::font_families(&options.settings())
}

/// The number of renders running, including renders that timed out and are being cancelled.
#[rustler::nif]
fn running_renders() -> usize {
    typsty_core::isolate::running_renders()
}

/// The version of the Typst compiler, such as "0.15.1".
#[rustler::nif]
fn typst_version() -> String {
    typsty_core::typst_version()
}

fn load(_env: Env, _info: Term) -> bool {
    typsty_core::init();
    true
}

rustler::init!("Elixir.Typsty.Native", load = load);
