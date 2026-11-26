//! The rules for components (`Typsty.Component`): Typst files that documents import, which
//! only define things. They're checked when a component's module compiles.
//!
//! - At its top level, a component may only have definitions (`#let`), imports (`#import`),
//!   comments and blank lines. Anything else (text, a function call, `#include`, a set or show
//!   rule) is refused: content outside a function never appears in a document that imports
//!   the component, and a set or show rule there only applies to the component's own file.
//! - A component can't read `sys.inputs`, where the document's assigns are, so it only gets
//!   data as arguments. The check is on the syntax: it catches `sys.inputs`,
//!   `std.sys.inputs` and imports of `inputs` from `sys`, not `sys` passed around under
//!   another name.

use typst::syntax::ast::{self, Expr, Imports};
use typst::syntax::{LinkedNode, Source, SyntaxKind};

use crate::diagnostics::Diagnostic;

const TOP_LEVEL: &str =
    "a component can only define things (with `#let`) and import them (with `#import`)";

const CONTENT_HINT: &str = "content outside a function doesn't appear in the documents that import the component. Put it in a function, and call the function from the document";

const RULE_HINT: &str = "a set or show rule outside a function only applies to the component's own file. Put it in a function, such as a template function that documents apply with `#show: name.with(..)`";

const INPUTS: &str = "a component can't read `sys.inputs`, which holds the document's assigns";

const INPUTS_HINT: &str =
    "take what the component needs as arguments, and pass it from the document";

/// The problems with a component's source, which is empty for a valid component: its syntax
/// errors if it has any (the other rules are only checked on valid syntax), and otherwise
/// what breaks the rules above.
pub fn errors(source: &Source) -> Vec<Diagnostic> {
    let (syntax_errors, _warnings) = source.root().errors_and_warnings();
    if !syntax_errors.is_empty() {
        return syntax_errors
            .iter()
            .map(|error| Diagnostic::from_syntax(error, source))
            .collect();
    }

    let mut errors = top_level_errors(source);
    errors.extend(input_errors(source));
    errors.sort_by_key(|error| (error.line, error.column));
    errors
}

/// What's at the top level besides definitions, imports, comments and blank lines: one
/// error per line.
fn top_level_errors(source: &Source) -> Vec<Diagnostic> {
    let root = LinkedNode::new(source.root());
    let mut errors: Vec<Diagnostic> = Vec::new();
    // The `#` before an expression in markup is a node of its own, before the expression's
    let mut hash = None;

    for child in root.children() {
        let hint = match child.kind() {
            SyntaxKind::Space
            | SyntaxKind::Parbreak
            | SyntaxKind::LineComment
            | SyntaxKind::BlockComment
            | SyntaxKind::Shebang
            | SyntaxKind::Semicolon => continue,
            SyntaxKind::Hash => {
                hash = Some(child.offset());
                continue;
            }
            SyntaxKind::LetBinding | SyntaxKind::ModuleImport => {
                hash = None;
                continue;
            }
            SyntaxKind::SetRule | SyntaxKind::ShowRule => RULE_HINT,
            _ => CONTENT_HINT,
        };

        let error = Diagnostic::at(
            source,
            hash.take().unwrap_or(child.offset()),
            TOP_LEVEL,
            hint,
        );

        if errors.last().is_none_or(|last| last.line != error.line) {
            errors.push(error);
        }
    }

    errors
}

/// Where the component reads `sys.inputs`.
fn input_errors(source: &Source) -> Vec<Diagnostic> {
    let mut errors = Vec::new();

    // Walked with a stack rather than recursively, since the tree can be deep
    let mut nodes = vec![LinkedNode::new(source.root())];
    while let Some(node) = nodes.pop() {
        if reads_inputs(&node) {
            errors.push(Diagnostic::at(source, node.offset(), INPUTS, INPUTS_HINT));
        } else {
            nodes.extend(node.children());
        }
    }

    errors
}

fn reads_inputs(node: &LinkedNode) -> bool {
    if let Some(access) = node.cast::<ast::FieldAccess>() {
        return access.field().as_str() == "inputs"
            && path(access.target()).is_some_and(|path| is_sys(&path));
    }

    let Some(import) = node.cast::<ast::ModuleImport>() else {
        return false;
    };
    let Some(source) = path(import.source()) else {
        return false;
    };

    // `import sys as s`, or `import sys: *`
    if is_sys(&source)
        && (import.new_name().is_some() || matches!(import.imports(), Some(Imports::Wildcard)))
    {
        return true;
    }

    let Some(Imports::Items(items)) = import.imports() else {
        return false;
    };

    items.iter().any(|item| {
        let mut full = source.clone();
        full.extend(item.path().iter().map(|ident| ident.as_str()));

        // `import sys: inputs`, `import std: sys.inputs`, or `import std: sys as s`
        let renames_sys = matches!(item, ast::ImportItem::Renamed(_)) && is_sys(&full);
        renames_sys || (1..full.len()).any(|end| is_sys(&full[..end]) && full[end] == "inputs")
    })
}

/// The identifiers of an expression made only of identifiers and field accesses: `std.sys`
/// is `["std", "sys"]`.
fn path<'a>(expr: Expr<'a>) -> Option<Vec<&'a str>> {
    match expr {
        Expr::Ident(ident) => Some(vec![ident.as_str()]),
        Expr::FieldAccess(access) => {
            let mut path = path(access.target())?;
            path.push(access.field().as_str());
            Some(path)
        }
        _ => None,
    }
}

fn is_sys(path: &[&str]) -> bool {
    matches!(path, ["sys"] | ["std", "sys"])
}

/// The functions that read a file from a path given as their first argument.
const READERS: &[&str] = &[
    "image",
    "read",
    "json",
    "yaml",
    "toml",
    "csv",
    "xml",
    "cbor",
    "plugin",
    "bibliography",
];

/// The paths that a component reads files from, written as strings: the first argument of
/// `image`, `read`, the data loading functions, `plugin` and `bibliography` (which takes an
/// array of them too), with the 1-based line and column of each string. They're checked
/// against the component's files when it compiles; paths built at runtime can't be.
pub fn file_paths(source: &Source) -> Vec<(String, usize, usize)> {
    let mut paths = Vec::new();

    // Walked with a stack rather than recursively, since the tree can be deep
    let mut nodes = vec![LinkedNode::new(source.root())];
    while let Some(node) = nodes.pop() {
        if let Some(path) = read_path(&node) {
            let strings: Vec<LinkedNode> = match path.kind() {
                SyntaxKind::Str => vec![path],
                SyntaxKind::Array => path
                    .children()
                    .filter(|item| item.kind() == SyntaxKind::Str)
                    .collect(),
                _ => Vec::new(),
            };

            for string in strings {
                let value = string.cast::<ast::Str>().map(|string| string.get());
                let position = source.lines().byte_to_line_column(string.offset());

                if let (Some(value), Some((line, column))) = (value, position) {
                    paths.push((value.to_string(), line + 1, column + 1));
                }
            }
        }

        nodes.extend(node.children());
    }

    paths.sort_by_key(|(_path, line, column)| (*line, *column));
    paths
}

/// The first positional argument of a call to one of the `READERS`.
fn read_path<'a>(node: &LinkedNode<'a>) -> Option<LinkedNode<'a>> {
    let call = node.cast::<ast::FuncCall>()?;
    let Expr::Ident(callee) = call.callee() else {
        return None;
    };

    if !READERS.contains(&callee.as_str()) {
        return None;
    }

    let args = node
        .children()
        .find(|child| child.kind() == SyntaxKind::Args)?;
    args.children()
        .find(|child| matches!(child.cast::<ast::Arg>(), Some(ast::Arg::Pos(_))))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn problems(text: &str) -> Vec<(usize, usize, String)> {
        errors(&Source::detached(text))
            .into_iter()
            .map(|error| (error.line.unwrap(), error.column.unwrap(), error.message))
            .collect()
    }

    #[test]
    fn allows_definitions_imports_comments_and_blank_lines() {
        let text = r##"// Brand colors
/* and helpers */
#import "brand.typ": blue
#import "@preview/oxifmt:1.0.0"

#let accent = rgb("#1a4d8f");
#let signature = [Best, Acme]
#let card(title: none, body) = {
  set text(fill: accent)
  show heading: set text(blue)
  [#title #body]
}
#let total = items => items.map(item => item.price).sum()
#let version = sys.version
"##;
        assert_eq!(problems(text), vec![]);
    }

    #[test]
    fn refuses_anything_else_at_the_top_level_once_per_line() {
        let text = "#let a = 1\nHello *world*\n#table(columns: 2)[a][b]\n#include \"other.typ\"\n#{ let b = 2 }\n= Heading\n";
        let lines: Vec<_> = problems(text)
            .into_iter()
            .map(|(line, column, message)| {
                assert_eq!(message, TOP_LEVEL);
                (line, column)
            })
            .collect();

        assert_eq!(lines, vec![(2, 1), (3, 1), (4, 1), (5, 1), (6, 1)]);
    }

    #[test]
    fn explains_why_set_and_show_rules_must_be_in_a_function() {
        let errors = errors(&Source::detached(
            "#set text(red)\n#show heading: set text(blue)\n#let x = 1; trailing\n",
        ));
        let hints: Vec<_> = errors.iter().map(|error| error.hints[0].as_str()).collect();

        assert_eq!(hints, vec![RULE_HINT, RULE_HINT, CONTENT_HINT]);
    }

    #[test]
    fn refuses_reading_sys_inputs() {
        for text in [
            "#let a = sys.inputs.assigns",
            "#let a() = std.sys.inputs",
            "#let a() = { let x = sys.inputs.at(\"assigns\"); x }",
            "#import sys: inputs",
            "#import sys: inputs as i",
            "#import sys: *",
            "#import sys as s",
            "#import std: sys.inputs",
            "#import std: sys as s",
            "#import std.sys: inputs",
        ] {
            assert_eq!(
                problems(text),
                vec![(1, problems(text)[0].1, INPUTS.to_string())],
                "{text}"
            );
        }

        for text in [
            "#import sys",
            "#import sys: version",
            "#import std: sys",
            "#let a = sys.version",
            "#let inputs = (a: 1)\n#let b = inputs.a",
            "#let a(x) = x.inputs",
        ] {
            assert_eq!(problems(text), vec![], "{text}");
        }
    }

    #[test]
    fn finds_the_paths_files_are_read_from() {
        let text = r##"#let logo = image("stamp/seal.svg", width: 1cm)
#let codes = json("stamp/data/codes.json")
#let refs = bibliography(("a.bib", "stamp/b.bib"), title: none)
#let dynamic(name) = image("stamp/" + name)
#let other = custom("stamp/not-read.svg")
#let text = read(encoding: none, "stamp/raw.bin")
"##;
        let paths: Vec<_> = file_paths(&Source::detached(text))
            .into_iter()
            .map(|(path, line, column)| (path, (line, column)))
            .collect();

        assert_eq!(
            paths,
            vec![
                ("stamp/seal.svg".to_string(), (1, 19)),
                ("stamp/data/codes.json".to_string(), (2, 19)),
                ("a.bib".to_string(), (3, 27)),
                ("stamp/b.bib".to_string(), (3, 36)),
                ("stamp/raw.bin".to_string(), (6, 34)),
            ]
        );
    }

    #[test]
    fn reports_syntax_errors_rather_than_the_other_rules() {
        let errors = errors(&Source::detached("Hello\n#let a = (\n"));

        assert!(!errors.is_empty());
        assert!(errors.iter().all(|error| error.message != TOP_LEVEL));
    }
}
