//! Rendering, checking and formatting templates.

use typst::foundations::Dict;
use typst::syntax::Source;
use typst_layout::PagedDocument;
use typst_pdf::PdfStandards;

use crate::diagnostics::{self, Diagnostic};
use crate::export::{self, Output};
use crate::fonts::{self, FontSettings};
use crate::isolate::{self, Cancellation};
use crate::world::{self, Prepared, TypstyWorld};

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

/// The exported document and Typst's warnings.
pub type Rendered = (Output, Vec<Diagnostic>);

/// A render's arguments, as the NIF and the worker receive them.
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
    /// Checks the arguments, which is quick, so that invalid ones are reported before the
    /// render waits for its turn. The error describes the invalid argument.
    pub fn prepare(self) -> Result<PreparedJob, String> {
        let pdf_standards = export::pdf_standards(&self.pdf_standards)?;

        if !(self.ppi.is_finite() && self.ppi > 0.0) {
            return Err(format!(
                "the :ppi option must be a positive number, got: {}",
                self.ppi
            ));
        }

        let world = Prepared::new(
            &self.template,
            self.variables,
            self.files,
            self.root,
            self.package_paths,
        )?;

        Ok(PreparedJob {
            world,
            fonts: self.fonts,
            format: self.format,
            ppi: self.ppi,
            pdf_standards,
        })
    }
}

/// A render whose arguments were checked (see `RenderJob::prepare`).
pub struct PreparedJob {
    world: Prepared,
    fonts: FontSettings,
    format: Format,
    ppi: f64,
    pdf_standards: PdfStandards,
}

impl PreparedJob {
    /// Compiles and exports the document. Runs on a render's thread (see `isolate::start`),
    /// and returns Typst's errors when it fails.
    pub fn render(self, cancellation: Cancellation) -> Result<Rendered, Vec<Diagnostic>> {
        let fonts = fonts::store(&self.fonts);

        // Evicted after exporting (rendering PNGs memoizes textures), and also when a
        // cancelled render unwinds
        let _evict = EvictOnDrop;

        let world = TypstyWorld::new(self.world, fonts, cancellation);
        let compiled = typst::compile::<PagedDocument>(&world);
        let warnings = diagnostics::from_sources(&compiled.warnings, &world);

        let document = compiled
            .output
            .map_err(|errors| diagnostics::from_sources(&errors, &world))?;

        let output = match self.format {
            Format::Pdf => export::pdf(&document, self.pdf_standards, &world)?,
            Format::Png => export::png(&document, self.ppi, &world)?,
            Format::Svg => export::svg(&document, &world),
        };

        Ok((output, warnings))
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

/// Checks a template's syntax. Returns the syntax errors, which is empty for a valid template.
pub fn syntax_errors(template: String) -> Vec<Diagnostic> {
    isolate::run(move || collect_syntax_errors(world::strip_bom(&template)))
        .unwrap_or_else(|interrupted| vec![Diagnostic::error(interrupted.message())])
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

    isolate::run(move || {
        let template = world::strip_bom(&template);

        typstyle_core::Typstyle::new(config)
            .format_text(template)
            .render()
            .map_err(|error| match collect_syntax_errors(template) {
                errors if errors.is_empty() => vec![Diagnostic::error(format!(
                    "typstyle couldn't format the template: {error}"
                ))],
                errors => errors,
            })
    })
    .unwrap_or_else(|interrupted| Err(vec![Diagnostic::error(interrupted.message())]))
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
