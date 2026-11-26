//! Typst's errors and warnings, with their locations, for `Typsty.Diagnostic` structs.

use typst::diag::SourceDiagnostic;
use typst::syntax::ast::{self, Expr};
use typst::syntax::{DiagSpan, LinkedNode, Side, Source, SyntaxDiagnostic, VirtualRoot};
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

    /// A warning without a location, for problems that aren't in a Typst file.
    pub fn warning(message: impl Into<String>) -> Self {
        Self {
            severity: Severity::Warning,
            ..Self::error(message)
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

        let mut hints: Vec<String> = diagnostic
            .hints
            .iter()
            .map(|hint| hint.v.to_string())
            .collect();
        hints.extend(missing_assign_hint(diagnostic, world));

        Self {
            severity,
            message: diagnostic.message.to_string(),
            hints,
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

/// A hint for an assign the template uses but wasn't given. Typst reports it like a key
/// missing from any dictionary, so the hint is only added when the template reads the key
/// from `assigns`: `assigns.customer`, `assigns.at("customer")`, or
/// `let (customer,) = assigns`.
fn missing_assign_hint(diagnostic: &SourceDiagnostic, world: &TypstyWorld) -> Option<String> {
    // The key is quoted, as a Typst string
    let key = diagnostic
        .message
        .strip_prefix("dictionary does not contain key ")?;
    let key = key
        .strip_suffix(" and no default value was specified")
        .unwrap_or(key);

    if diagnostic.span.id()? != world.main_source().id() {
        return None;
    }

    let range = world.range(diagnostic.span)?;
    let root = LinkedNode::new(world.main_source().root());
    let mut node = root.leaf_at(range.start, Side::After)?;

    // The nearest expression that reads from a dictionary decides
    let reads_assigns = loop {
        if let Some(access) = node.cast::<ast::FieldAccess>() {
            break is_assigns(access.target());
        }

        if let Some(call) = node.cast::<ast::FuncCall>() {
            break matches!(call.callee(), Expr::FieldAccess(access) if is_assigns(access.target()));
        }

        if let Some(binding) = node.cast::<ast::LetBinding>() {
            break binding.init().is_some_and(is_assigns);
        }

        node = node.parent()?.clone();
    };

    reads_assigns.then(|| {
        format!("there's no {key} in the assigns. Pass it from Elixir, or read it with `assigns.at({key}, default: none)` if it's optional")
    })
}

fn is_assigns(expr: Expr) -> bool {
    matches!(expr, Expr::Ident(ident) if ident.as_str() == "assigns")
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
        let lines = if main {
            world.main_source().lines().clone()
        } else {
            world.lines(id)?
        };

        lines.byte_to_line_column(range.start)
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
