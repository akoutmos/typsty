//! Rendering, checking and formatting templates.

use typst::foundations::{Dict, Value};
use typst::syntax::Source;
use typst_layout::PagedDocument;
use typst_pdf::PdfStandards;

use crate::diagnostics::{self, Diagnostic};
use crate::export::{self, Output};
use crate::fonts::{self, FontSettings};
use crate::isolate::{self, Cancellation};
use crate::world::{self, PrepareError, Prepared, TypstyWorld};

/// How many compilations a memoized result survives without being used. Typst memoizes
/// evaluation, layout, decoded images and rendered textures across compilations, which
/// speeds up rendering the same template again; evicting old results keeps memory bounded.
const CACHE_MAX_AGE: usize = 10;

/// Renders whose assigns and files take more than about this much memory evict everything
/// Typst memoized as soon as they're done, rather than let the cache keep them alive for
/// `CACHE_MAX_AGE` more renders: 32 MiB.
const LARGE_INPUT: usize = 32 * 1024 * 1024;

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
    pub assigns: Dict,
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
    /// render waits for its turn.
    pub fn prepare(self) -> Result<PreparedJob, PrepareError> {
        let pdf_standards =
            export::pdf_standards(&self.pdf_standards).map_err(PrepareError::Invalid)?;

        if !(self.ppi.is_finite() && self.ppi > 0.0) {
            return Err(PrepareError::Invalid(format!(
                "the :ppi option must be a positive number, got: {}",
                self.ppi
            )));
        }

        let files_size: usize = self.files.iter().map(|(_path, bytes)| bytes.len()).sum();
        let large = files_size.saturating_add(approximate_size(&self.assigns)) > LARGE_INPUT;

        let world = Prepared::new(
            self.template,
            self.assigns,
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
            large,
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
    /// Whether the assigns and files are large (see `LARGE_INPUT`).
    large: bool,
}

impl PreparedJob {
    /// Compiles and exports the document. Runs on a render's thread (see `isolate::start`),
    /// and returns Typst's errors when it fails.
    pub fn render(self, cancellation: Cancellation) -> Result<Rendered, Vec<Diagnostic>> {
        let fonts = fonts::store(&self.fonts);

        // Evicted after exporting (rendering PNGs memoizes textures), and also when a
        // cancelled render unwinds
        let _evict = EvictOnDrop(if self.large { 0 } else { CACHE_MAX_AGE });

        let world = TypstyWorld::new(self.world, fonts, cancellation);
        let compiled = typst::compile::<PagedDocument>(&world);
        let mut warnings = diagnostics::from_sources(&compiled.warnings, &world);

        // The warnings often explain the errors (an unknown font, say), so they come along
        let document = compiled.output.map_err(|errors| {
            let mut diagnostics = diagnostics::from_sources(&errors, &world);
            diagnostics.append(&mut warnings);
            diagnostics
        })?;

        let output = match self.format {
            Format::Pdf => export::pdf(&document, self.pdf_standards, &world, &mut warnings)?,
            Format::Png => export::png(&document, self.ppi, &world)?,
            Format::Svg => export::svg(&document, &world, &mut warnings),
        };

        Ok((output, warnings))
    }
}

/// Drops everything Typst has memoized, such as decoded images and laid out content.
pub fn clear_caches() {
    comemo::evict(0);
}

/// Evicts what Typst memoized that's older than the given number of renders.
struct EvictOnDrop(usize);

impl Drop for EvictOnDrop {
    fn drop(&mut self) {
        comemo::evict(self.0);
    }
}

/// Roughly how much memory the assigns take in Typst, counting up to `LARGE_INPUT`.
fn approximate_size(assigns: &Dict) -> usize {
    let mut size = 0;
    let mut pending: Vec<&Value> = assigns.iter().map(|(_key, value)| value).collect();

    while let Some(value) = pending.pop() {
        if size > LARGE_INPUT {
            break;
        }

        size += std::mem::size_of::<Value>();
        match value {
            Value::Str(text) => size += text.len(),
            Value::Array(array) => pending.extend(array.iter()),
            Value::Dict(dict) => {
                for (key, value) in dict.iter() {
                    size += key.len();
                    pending.push(value);
                }
            }
            _ => {}
        }
    }

    size
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

/// The packages a Typst file imports or includes, such as `@preview/oxifmt:1.0.0`, found by
/// parsing it: imports in comments, strings and raw text don't count.
pub fn package_imports(text: String) -> Vec<String> {
    use std::str::FromStr;
    use typst::syntax::ast::{self, Expr};
    use typst::syntax::package::PackageSpec;

    isolate::run(move || {
        let root = typst::syntax::parse(world::strip_bom(&text));
        let mut specs = Vec::new();

        // Walked with a stack rather than recursively, since the tree can be deep
        let mut nodes = vec![&root];
        while let Some(node) = nodes.pop() {
            let source = node
                .cast::<ast::ModuleImport>()
                .map(|import| import.source())
                .or_else(|| {
                    node.cast::<ast::ModuleInclude>()
                        .map(|include| include.source())
                });

            if let Some(Expr::Str(string)) = source {
                if let Ok(spec) = PackageSpec::from_str(&string.get()) {
                    specs.push(spec.to_string());
                }
            }

            nodes.extend(node.children());
        }

        specs.sort();
        specs.dedup();
        specs
    })
    .unwrap_or_default()
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
