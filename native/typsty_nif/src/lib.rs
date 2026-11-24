//! Native functions for Typsty: compiling Typst documents to PDF, PNG and SVG, checking
//! template syntax and formatting templates with typstyle.

mod diagnostics;
mod fonts;
mod value;
mod world;

use rustler::{Atom, Binary, Encoder, Env, NewBinary, NifMap, Term};
use typst::foundations::Smart;
use typst::syntax::Source;
use typst::utils::Scalar;
use typst_layout::PagedDocument;
use typst_pdf::{PdfOptions, PdfStandard, PdfStandards, Timestamp};

use diagnostics::Diagnostic;
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
/// layout and evaluation results across compilations, which speeds up rendering the same
/// template again; evicting old results keeps memory use bounded.
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
}

#[derive(NifMap)]
struct FormatOptions {
    line_width: usize,
    indent_width: usize,
    wrap_text: bool,
}

/// Compiles a template and exports it.
///
/// Returns `{:ok, output, warnings}`, where the output is a binary for PDF and a list of
/// binaries (one per page) for PNG and SVG, `{:error, diagnostics}` when Typst fails, or
/// `{:error, message}` when the arguments are invalid.
#[rustler::nif(schedule = "DirtyCpu")]
fn render<'a>(
    env: Env<'a>,
    template: &str,
    variables: Term<'a>,
    files: Vec<(String, Binary<'a>)>,
    options: RenderOptions,
) -> Term<'a> {
    let variables = match value::to_dict(variables) {
        Ok(variables) => variables,
        Err(message) => return (atoms::error(), message).encode(env),
    };

    let world_options = WorldOptions {
        files: files
            .into_iter()
            .map(|(path, bytes)| (path, bytes.as_slice().to_vec()))
            .collect(),
        root: options.root,
        package_paths: options.package_paths,
        fonts: fonts::store(&options.fonts.settings()),
    };

    let world = match TypstyWorld::new(template, variables, world_options) {
        Ok(world) => world,
        Err(message) => return (atoms::error(), message).encode(env),
    };

    let compiled = typst::compile::<PagedDocument>(&world);
    comemo::evict(CACHE_MAX_AGE);

    let warnings = diagnostics::from_sources(&compiled.warnings, &world);
    let document = match compiled.output {
        Ok(document) => document,
        Err(errors) => {
            return (atoms::error(), diagnostics::from_sources(&errors, &world)).encode(env)
        }
    };

    let output = if options.format == atoms::pdf() {
        export_pdf(env, &document, &options.pdf_standards, &world)
    } else if options.format == atoms::png() {
        export_png(env, &document, options.ppi)
    } else if options.format == atoms::svg() {
        Ok(export_svg(env, &document))
    } else {
        Err(vec![Diagnostic::error("unknown format")])
    };

    match output {
        Ok(output) => (atoms::ok(), output, warnings).encode(env),
        Err(errors) => (atoms::error(), errors).encode(env),
    }
}

fn export_pdf<'a>(
    env: Env<'a>,
    document: &PagedDocument,
    standards: &[String],
    world: &TypstyWorld,
) -> Result<Term<'a>, Vec<Diagnostic>> {
    let standards = standards
        .iter()
        .map(|standard| pdf_standard(standard))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|message| vec![Diagnostic::error(message)])?;

    let standards = PdfStandards::new(&standards)
        .map_err(|error| vec![Diagnostic::error(error.message().to_string())])?;

    let options = PdfOptions {
        standards,
        // Without an identifier, Typst derives one from the document's title and author
        ident: Smart::Auto,
        // Like the Typst CLI, `set document(date: auto)` (the default) is the time of the
        // render. Templates set `date: none` to leave it out, for reproducible PDFs.
        timestamp: Some(Timestamp::new_utc(world.now())),
        ..PdfOptions::default()
    };

    let pdf = typst_pdf::pdf(document, &options)
        .map_err(|errors| diagnostics::from_sources(&errors, world))?;

    Ok(binary(env, &pdf))
}

fn export_png<'a>(
    env: Env<'a>,
    document: &PagedDocument,
    ppi: f64,
) -> Result<Term<'a>, Vec<Diagnostic>> {
    let options = typst_render::RenderOptions {
        pixel_per_pt: Scalar::new(ppi / 72.0),
        ..typst_render::RenderOptions::default()
    };

    let pages = document
        .pages()
        .iter()
        .enumerate()
        .map(|(index, page)| {
            let png = typst_render::render(page, &options)
                .encode_png()
                .map_err(|error| {
                    vec![Diagnostic::error(format!(
                        "failed to encode page {} as PNG: {error}",
                        index + 1
                    ))]
                })?;

            Ok(binary(env, &png))
        })
        .collect::<Result<Vec<Term<'a>>, Vec<Diagnostic>>>()?;

    Ok(pages.encode(env))
}

fn export_svg<'a>(env: Env<'a>, document: &PagedDocument) -> Term<'a> {
    let options = typst_svg::SvgOptions::default();

    document
        .pages()
        .iter()
        .map(|page| binary(env, typst_svg::svg(page, &options).as_bytes()))
        .collect::<Vec<_>>()
        .encode(env)
}

fn pdf_standard(name: &str) -> Result<PdfStandard, String> {
    Ok(match name {
        "1.4" => PdfStandard::V_1_4,
        "1.5" => PdfStandard::V_1_5,
        "1.6" => PdfStandard::V_1_6,
        "1.7" => PdfStandard::V_1_7,
        "2.0" => PdfStandard::V_2_0,
        "a-1b" => PdfStandard::A_1b,
        "a-1a" => PdfStandard::A_1a,
        "a-2b" => PdfStandard::A_2b,
        "a-2u" => PdfStandard::A_2u,
        "a-2a" => PdfStandard::A_2a,
        "a-3b" => PdfStandard::A_3b,
        "a-3u" => PdfStandard::A_3u,
        "a-3a" => PdfStandard::A_3a,
        "a-4" => PdfStandard::A_4,
        "a-4f" => PdfStandard::A_4f,
        "a-4e" => PdfStandard::A_4e,
        "ua-1" => PdfStandard::Ua_1,
        other => return Err(format!("unknown PDF standard: {other}")),
    })
}

fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = NewBinary::new(env, bytes.len());
    binary.as_mut_slice().copy_from_slice(bytes);
    Binary::from(binary).encode(env)
}

/// Checks a template's syntax. Returns the syntax errors, which is an empty list for a valid
/// template.
#[rustler::nif(schedule = "DirtyCpu")]
fn syntax_errors(template: &str) -> Vec<Diagnostic> {
    collect_syntax_errors(template)
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
fn format<'a>(env: Env<'a>, template: &str, options: FormatOptions) -> Term<'a> {
    let config = typstyle_core::Config::new()
        .with_width(options.line_width)
        .with_tab_spaces(options.indent_width)
        .with_wrap_text(options.wrap_text);

    match typstyle_core::Typstyle::new(config)
        .format_text(template)
        .render()
    {
        Ok(formatted) => (atoms::ok(), formatted).encode(env),
        Err(_) => (atoms::error(), collect_syntax_errors(template)).encode(env),
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

rustler::init!("Elixir.Typsty.Native");
