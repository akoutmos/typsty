//! Rendering, checking and formatting templates.

use std::time::Duration;

use typst::foundations::Dict;
use typst::syntax::Source;
use typst_layout::PagedDocument;

use crate::diagnostics::{self, Diagnostic};
use crate::export::{self, Output};
use crate::fonts::{self, FontSettings};
use crate::isolate::{self, Cancellation};
use crate::world::{TypstyWorld, WorldOptions};

/// How many compilations a memoized result survives without being used. Typst memoizes
/// evaluation, layout, decoded images and rendered textures across compilations, which
/// speeds up rendering the same template again; evicting old results keeps memory bounded.
const CACHE_MAX_AGE: usize = 10;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Pdf,
    Png,
    Svg,
}

impl Format {
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "pdf" => Some(Format::Pdf),
            "png" => Some(Format::Png),
            "svg" => Some(Format::Svg),
            _ => None,
        }
    }
}

pub enum Failure {
    /// The arguments are invalid, which is raised as an `ArgumentError`.
    Invalid(String),
    /// Typst reported errors, or the render failed.
    Diagnostics(Vec<Diagnostic>),
}

/// The exported document and Typst's warnings.
pub type Rendered = (Output, Vec<Diagnostic>);

pub struct RenderJob {
    pub template: String,
    pub variables: Dict,
    pub files: Vec<(String, Vec<u8>)>,
    pub format: Format,
    pub root: Option<String>,
    pub package_paths: Vec<String>,
    pub fonts: FontSettings,
    pub ppi: f64,
    pub pdf_standards: Vec<String>,
}

impl RenderJob {
    /// Renders on a thread of its own (see `isolate`), waiting for it up to the timeout, which
    /// includes waiting for one of the `limit` slots for renders running at once. The outer
    /// error is the render not finishing: it timed out, panicked, or couldn't start.
    pub fn render(
        self,
        timeout: Option<Duration>,
        limit: Option<usize>,
    ) -> Result<Result<Rendered, Failure>, isolate::Failure> {
        isolate::run(timeout, limit, move |cancellation| self.run(cancellation))
    }

    fn run(self, cancellation: Cancellation) -> Result<Rendered, Failure> {
        let world_options = WorldOptions {
            files: self.files,
            root: self.root,
            package_paths: self.package_paths,
            fonts: fonts::store(&self.fonts),
            cancellation,
        };

        // Evicted after exporting (rendering PNGs memoizes textures), and also when a
        // cancelled render unwinds
        let _evict = EvictOnDrop;

        let world = TypstyWorld::new(&self.template, self.variables, world_options)
            .map_err(Failure::Invalid)?;

        compile_and_export(&world, self.format, self.ppi, &self.pdf_standards)
    }
}

/// Drops everything Typst has memoized, such as decoded images and laid out content.
pub fn clear_caches() {
    comemo::evict(0);
}

struct EvictOnDrop;

impl Drop for EvictOnDrop {
    fn drop(&mut self) {
        comemo::evict(CACHE_MAX_AGE);
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
        Format::Png => export::png(&document, ppi, world),
        Format::Svg => Ok(export::svg(&document, world)),
    }
    .map_err(Failure::Diagnostics)?;

    Ok((output, warnings))
}

/// Checks a template's syntax. Returns the syntax errors, which is empty for a valid template.
pub fn syntax_errors(template: String) -> Vec<Diagnostic> {
    isolate::run(None, None, move |_cancellation| {
        collect_syntax_errors(&template)
    })
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

/// Formats a template with typstyle. A template with syntax errors can't be formatted, so it
/// returns them instead.
pub fn format(
    template: String,
    line_width: usize,
    indent_width: usize,
    wrap_text: bool,
) -> Result<String, Vec<Diagnostic>> {
    let config = typstyle_core::Config::new()
        .with_width(line_width)
        .with_tab_spaces(indent_width)
        .with_wrap_text(wrap_text);

    isolate::run(None, None, move |_cancellation| {
        typstyle_core::Typstyle::new(config)
            .format_text(template.as_str())
            .render()
            .map_err(|_| collect_syntax_errors(&template))
    })
    .unwrap_or_else(|failure| Err(vec![Diagnostic::error(failure.message())]))
}

/// Scans for fonts (caching them for later renders) and returns the font families found.
pub fn font_families(settings: &FontSettings) -> Vec<String> {
    let store = fonts::store(settings);
    let mut families: Vec<String> = store
        .book()
        .families()
        .map(|(family, _)| family.to_string())
        .collect();

    families.sort();
    families.dedup();
    families
}
