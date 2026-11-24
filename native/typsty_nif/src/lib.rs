//! Native functions for Typsty: compiling Typst documents to PDF, PNG and SVG, checking
//! template syntax and formatting templates with typstyle.
//!
//! Terms are decoded and encoded on the NIF's own thread, and everything Typst does runs on
//! a separate thread with a large stack (see `isolate`).

mod checks;
mod diagnostics;
mod export;
mod fonts;
mod isolate;
mod value;
mod world;

use std::time::Duration;

use rustler::{Atom, Binary, Encoder, Env, NewBinary, NifMap, Term};
use typst::foundations::Dict;
use typst::syntax::Source;
use typst_layout::PagedDocument;

use diagnostics::Diagnostic;
use export::Output;
use fonts::FontSettings;
use world::{TypstyWorld, WorldOptions};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        pdf,
        png,
        svg,
    }
}

/// How many compilations a memoized result survives without being used. Typst memoizes
/// evaluation, layout, decoded images and rendered textures across compilations, which
/// speeds up rendering the same template again; evicting old results keeps memory bounded.
const CACHE_MAX_AGE: usize = 10;

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
}

#[derive(NifMap)]
struct FormatOptions {
    line_width: usize,
    indent_width: usize,
    wrap_text: bool,
}

#[derive(Clone, Copy)]
enum Format {
    Pdf,
    Png,
    Svg,
}

enum Failure {
    /// The arguments are invalid, which is raised as an `ArgumentError`.
    Invalid(String),
    /// Typst reported errors, or the render failed.
    Diagnostics(Vec<Diagnostic>),
}

type Rendered = (Output, Vec<Diagnostic>);

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

    let files: Vec<(String, Vec<u8>)> = files
        .into_iter()
        .map(|(path, bytes)| (path, bytes.as_slice().to_vec()))
        .collect();

    let timeout = options.timeout.map(Duration::from_millis);
    let job = RenderJob {
        template,
        variables,
        files,
        format,
        root: options.root,
        package_paths: options.package_paths,
        fonts: options.fonts.settings(),
        ppi: options.ppi,
        pdf_standards: options.pdf_standards,
    };

    let result = isolate::run(timeout, move || job.run()).unwrap_or_else(|failure| {
        Err(Failure::Diagnostics(vec![Diagnostic::error(
            failure.message(),
        )]))
    });

    match result {
        Ok((output, warnings)) => (atoms::ok(), encode_output(env, output), warnings).encode(env),
        Err(Failure::Invalid(message)) => (atoms::error(), message).encode(env),
        Err(Failure::Diagnostics(diagnostics)) => (atoms::error(), diagnostics).encode(env),
    }
}

struct RenderJob {
    template: String,
    variables: Dict,
    files: Vec<(String, Vec<u8>)>,
    format: Format,
    root: Option<String>,
    package_paths: Vec<String>,
    fonts: FontSettings,
    ppi: f64,
    pdf_standards: Vec<String>,
}

impl RenderJob {
    fn run(self) -> Result<Rendered, Failure> {
        let world_options = WorldOptions {
            files: self.files,
            root: self.root,
            package_paths: self.package_paths,
            fonts: fonts::store(&self.fonts),
        };

        let world = TypstyWorld::new(&self.template, self.variables, world_options)
            .map_err(Failure::Invalid)?;

        let result = compile_and_export(&world, self.format, self.ppi, &self.pdf_standards);

        // Evicted after exporting too, since rendering PNGs memoizes textures
        comemo::evict(CACHE_MAX_AGE);
        result
    }
}

fn compile_and_export(
    world: &TypstyWorld,
    format: Format,
    ppi: f64,
    pdf_standards: &[String],
) -> Result<Rendered, Failure> {
    let compiled = typst::compile::<PagedDocument>(world);
    let warnings = diagnostics::from_sources(&compiled.warnings, world);

    let document = compiled
        .output
        .map_err(|errors| Failure::Diagnostics(diagnostics::from_sources(&errors, world)))?;

    let output = match format {
        Format::Pdf => export::pdf(&document, pdf_standards, world),
        Format::Png => export::png(&document, ppi),
        Format::Svg => Ok(export::svg(&document)),
    }
    .map_err(Failure::Diagnostics)?;

    Ok((output, warnings))
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
    isolate::run(None, move || collect_syntax_errors(&template))
        .unwrap_or_else(|failure| vec![Diagnostic::error(failure.message())])
}

fn collect_syntax_errors(template: &str) -> Vec<Diagnostic> {
    let source = Source::detached(template);
    let (errors, _warnings) = source.root().errors_and_warnings();

    errors
        .iter()
        .map(|error| Diagnostic::from_syntax(error, &source))
        .collect()
}

/// Formats a template with typstyle. Returns `{:error, diagnostics}` when the template has
/// syntax errors, since it can't be formatted then.
#[rustler::nif(schedule = "DirtyCpu")]
fn format<'a>(env: Env<'a>, template: String, options: FormatOptions) -> Term<'a> {
    let config = typstyle_core::Config::new()
        .with_width(options.line_width)
        .with_tab_spaces(options.indent_width)
        .with_wrap_text(options.wrap_text);

    let result = isolate::run(None, move || {
        typstyle_core::Typstyle::new(config)
            .format_text(template.as_str())
            .render()
            .map_err(|_| collect_syntax_errors(&template))
    })
    .unwrap_or_else(|failure| Err(vec![Diagnostic::error(failure.message())]));

    match result {
        Ok(formatted) => (atoms::ok(), formatted).encode(env),
        Err(diagnostics) => (atoms::error(), diagnostics).encode(env),
    }
}

/// Scans for fonts (caching them for later renders) and returns the font families found.
#[rustler::nif(schedule = "DirtyIo")]
fn font_families(options: FontOptions) -> Vec<String> {
    let store = fonts::store(&options.settings());
    let mut families: Vec<String> = store
        .book()
        .families()
        .map(|(family, _)| family.to_string())
        .collect();

    families.sort();
    families.dedup();
    families
}

/// The version of the Typst compiler, such as "0.15.1".
#[rustler::nif]
fn typst_version() -> String {
    let version = typst::utils::version();
    format!(
        "{}.{}.{}",
        version.major(),
        version.minor(),
        version.patch()
    )
}

fn load(_env: Env, _info: Term) -> bool {
    isolate::init_panic_hook();
    isolate::init_thread_pool();
    true
}

rustler::init!("Elixir.Typsty.Native", load = load);
