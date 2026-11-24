//! Typst's errors and warnings, with their locations, for `Typsty.Diagnostic` structs.

use typst::diag::SourceDiagnostic;
use typst::syntax::{DiagSpan, Source, SyntaxDiagnostic, VirtualRoot};
use typst::WorldExt;

use crate::world::TypstyWorld;

// Diagnostics are built on the thread that runs Typst, and encoded as terms by the NIF or
// the worker, so they're plain data.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Severity {
    Error,
    Warning,
}

#[derive(Clone, Debug)]
pub struct Diagnostic {
    pub severity: Severity,
    pub message: String,
    pub hints: Vec<String>,
    /// `None` for the template itself, otherwise the path of the file in the project, or
    /// `@namespace/name:version/path` for a file in a package.
    pub file: Option<String>,
    /// 1-based, or `None` when the problem has no location.
    pub line: Option<usize>,
    pub column: Option<usize>,
    pub trace: Vec<TracePoint>,
}

#[derive(Clone, Debug)]
pub struct TracePoint {
    pub message: String,
    pub file: Option<String>,
    pub line: Option<usize>,
    pub column: Option<usize>,
}

impl Diagnostic {
    /// A diagnostic without a location, for problems that aren't in a Typst file.
    pub fn error(message: impl Into<String>) -> Self {
        Self {
            severity: Severity::Error,
            message: message.into(),
            hints: Vec::new(),
            file: None,
            line: None,
            column: None,
            trace: Vec::new(),
        }
    }

    pub fn from_source(diagnostic: &SourceDiagnostic, world: &TypstyWorld) -> Self {
        let severity = match diagnostic.severity {
            typst::diag::Severity::Error => Severity::Error,
            typst::diag::Severity::Warning => Severity::Warning,
        };
        let (file, line, column) = locate(diagnostic.span, world);

        let trace = diagnostic
            .trace
            .iter()
            .map(|point| {
                let (file, line, column) = locate(point.span.into(), world);
                TracePoint {
                    message: point.v.to_string(),
                    file,
                    line,
                    column,
                }
            })
            .collect();

        Self {
            severity,
            message: diagnostic.message.to_string(),
            hints: diagnostic
                .hints
                .iter()
                .map(|hint| hint.v.to_string())
                .collect(),
            file,
            line,
            column,
            trace,
        }
    }

    /// A syntax error in a template that was parsed on its own (not as part of a world).
    pub fn from_syntax(diagnostic: &SyntaxDiagnostic, source: &Source) -> Self {
        let position = range(diagnostic.span, source).and_then(|range| {
            source
                .lines()
                .byte_to_line_column(range.start)
                .map(|(line, column)| (line + 1, column + 1))
        });

        Self {
            severity: if diagnostic.is_error {
                Severity::Error
            } else {
                Severity::Warning
            },
            message: diagnostic.message.to_string(),
            hints: diagnostic
                .hints
                .iter()
                .map(|hint| hint.v.to_string())
                .collect(),
            file: None,
            line: position.map(|(line, _)| line),
            column: position.map(|(_, column)| column),
            trace: Vec::new(),
        }
    }
}

pub fn from_sources<'a>(
    diagnostics: impl IntoIterator<Item = &'a SourceDiagnostic>,
    world: &TypstyWorld,
) -> Vec<Diagnostic> {
    diagnostics
        .into_iter()
        .map(|diagnostic| Diagnostic::from_source(diagnostic, world))
        .collect()
}

fn range(span: DiagSpan, source: &Source) -> Option<std::ops::Range<usize>> {
    match span.get() {
        typst::syntax::DiagSpanKind::Number { num, sub_range, .. } => source.range(num, sub_range),
        typst::syntax::DiagSpanKind::Range { range, .. } => Some(range),
        typst::syntax::DiagSpanKind::Detached => None,
    }
}

/// The file, line and column (both 1-based) of a span. Lines in the template don't count
/// the preamble that binds the assigns.
fn locate(span: DiagSpan, world: &TypstyWorld) -> (Option<String>, Option<usize>, Option<usize>) {
    let Some(id) = span.id() else {
        return (None, None, None);
    };

    let main = id == world.main_source().id();
    let file = if main {
        None
    } else {
        let path = id.vpath().get_with_slash();
        Some(match id.root() {
            VirtualRoot::Project => path.to_string(),
            VirtualRoot::Package(package) => format!("{package}{path}"),
        })
    };

    let position = world.range(span).and_then(|range| {
        let source = if main {
            world.main_source().clone()
        } else {
            typst::World::source(world, id).ok()?
        };

        source.lines().byte_to_line_column(range.start)
    });

    match position {
        Some((line, column)) if main => {
            // A span in the preamble points at the template's first line
            let line = line.saturating_sub(world.preamble_lines());
            (file, Some(line + 1), Some(column + 1))
        }
        Some((line, column)) => (file, Some(line + 1), Some(column + 1)),
        None => (file, None, None),
    }
}
