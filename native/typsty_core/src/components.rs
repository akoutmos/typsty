//! The rules for components (`Typsty.Component`): Typst files that documents import, which
//! only define things. They're checked when a component's module compiles.
//!
//! - At its top level, a component may only have definitions (`#let`), imports (`#import`),
//!   comments and blank lines. Anything else (text, a function call, `#include`, a set or show
//!   rule) is refused: content outside a function never appears in a document that imports
//!   the component, and a set or show rule there only applies to the component's own file.
//! - A component can't read `sys.inputs`, where the document's assigns are, so it only gets
//!   data as arguments. `sys` (and `std.sys`) may only be used to read their other fields, so
//!   it can't be passed around or renamed, and `eval`, which can read it too, is refused. The
//!   check is on the syntax, without following scopes: a parameter named `sys` is taken for
//!   the real one.

use typst::syntax::ast::{self, AstNode, Expr, Imports};
use typst::syntax::{LinkedNode, Source, SyntaxKind};

use crate::diagnostics::Diagnostic;

const TOP_LEVEL: &str =
    "a component can only define things (with `#let`) and import them (with `#import`)";

const CONTENT_HINT: &str = "content outside a function doesn't appear in the documents that import the component. Put it in a function, and call the function from the document";

const RULE_HINT: &str = "a set or show rule outside a function only applies to the component's own file. Put it in a function, such as a template function that documents apply with `#show: name.with(..)`";

const INPUTS: &str = "a component can't read `sys.inputs`, which holds the document's assigns";

const INPUTS_HINT: &str = "use `sys` only to read its other fields (like `sys.version`), and take what the component needs as arguments, passed from the document";

const EVAL: &str = "a component can't use `eval`, which can read `sys.inputs`";

const EVAL_HINT: &str = "build what the component needs from its arguments instead";

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

/// Where the component reads `sys.inputs`, or could: `sys` (and `std`, which holds it) may
/// only be used to read their fields, other than `inputs` (and `std.sys.inputs`), and `eval`
/// can't be used at all, since it evaluates code that could.
fn input_errors(source: &Source) -> Vec<Diagnostic> {
    let mut errors = Vec::new();

    // Walked with a stack rather than recursively, since the tree can be deep
    let mut nodes = vec![LinkedNode::new(source.root())];
    while let Some(node) = nodes.pop() {
        if let Some(problem) = forbidden_use(&node) {
            let (message, hint) = match problem {
                Forbidden::Inputs => (INPUTS, INPUTS_HINT),
                Forbidden::Eval => (EVAL, EVAL_HINT),
            };
            errors.push(Diagnostic::at(source, node.offset(), message, hint));
        }

        nodes.extend(node.children());
    }

    errors
}

enum Forbidden {
    Inputs,
    Eval,
}

/// Whether the node is an identifier that the component can't use there: `sys` or `std`
/// other than to read a field (or to import from them), or `eval`.
fn forbidden_use(node: &LinkedNode) -> Option<Forbidden> {
    // Identifiers in math, as in `$std.sys.inputs$`, are math identifiers
    let name = match (node.cast::<ast::Ident>(), node.cast::<ast::MathIdent>()) {
        (Some(ident), _) => ident.as_str(),
        (_, Some(ident)) => ident.as_str(),
        _ => return None,
    };
    if !matches!(name, "sys" | "std" | "eval") || is_binding(node) {
        return None;
    }

    let parent = node.parent()?;

    if let Some(access) = parent.cast::<ast::FieldAccess>() {
        // The field of a field access, as in `assigns.sys`, is only a name
        if !std::ptr::eq(access.target().to_untyped(), node.get()) {
            return None;
        }

        return match (name, access.field().as_str()) {
            ("sys", "inputs") => Some(Forbidden::Inputs),
            ("sys", _) => None,
            ("std", "eval") => Some(Forbidden::Eval),
            ("std", "sys") => std_sys_use(parent),
            ("std", _) => None,
            _ => Some(Forbidden::Eval),
        };
    }

    if let Some(import) = parent.cast::<ast::ModuleImport>() {
        if std::ptr::eq(import.source().to_untyped(), node.get()) {
            return forbidden_import(name, import);
        }
    }

    Some(if name == "eval" {
        Forbidden::Eval
    } else {
        Forbidden::Inputs
    })
}

/// `std.sys` may only be used to read one of its fields other than `inputs`.
fn std_sys_use(std_sys: &LinkedNode) -> Option<Forbidden> {
    let grandparent = std_sys.parent()?;

    match grandparent.cast::<ast::FieldAccess>() {
        Some(access) if std::ptr::eq(access.target().to_untyped(), std_sys.get()) => {
            (access.field().as_str() == "inputs").then_some(Forbidden::Inputs)
        }
        _ => Some(Forbidden::Inputs),
    }
}

/// Imports from `sys` or `std` may bring in their fields under their names, which are then
/// checked where they're used, but not `inputs` or `eval`, nor rename `sys` or `std`.
fn forbidden_import(name: &str, import: ast::ModuleImport) -> Option<Forbidden> {
    if name == "eval" || import.new_name().is_some() {
        return Some(if name == "eval" {
            Forbidden::Eval
        } else {
            Forbidden::Inputs
        });
    }

    let items = match import.imports() {
        // `import sys: *` brings `inputs` in; `import std: *` only brings `sys` and `eval` in
        // under their names, which are checked where they're used
        Some(Imports::Wildcard) => return (name == "sys").then_some(Forbidden::Inputs),
        Some(Imports::Items(items)) => items,
        None => return None,
    };

    items.iter().find_map(|item| {
        let path: Vec<&str> = item.path().iter().map(|ident| ident.as_str()).collect();
        let renamed = matches!(item, ast::ImportItem::Renamed(_));

        match (name, path.as_slice()) {
            ("sys", ["inputs", ..]) => Some(Forbidden::Inputs),
            ("std", ["sys", "inputs", ..]) => Some(Forbidden::Inputs),
            ("std", ["sys"]) if renamed => Some(Forbidden::Inputs),
            ("std", ["eval", ..]) => Some(Forbidden::Eval),
            _ => None,
        }
    })
}

/// Whether an identifier names what's being bound rather than using it: a `let` binding's
/// name or pattern, a parameter, a loop variable, an argument's or a dictionary entry's
/// name, or the name an import binds.
fn is_binding(node: &LinkedNode) -> bool {
    let Some(parent) = node.parent() else {
        return false;
    };

    if let Some(binding) = parent.cast::<ast::LetBinding>() {
        return binding
            .init()
            .is_none_or(|init| !std::ptr::eq(init.to_untyped(), node.get()));
    }

    if let Some(closure) = parent.cast::<ast::Closure>() {
        return closure
            .name()
            .is_some_and(|name| std::ptr::eq(name.to_untyped(), node.get()));
    }

    if let Some(named) = parent.cast::<ast::Named>() {
        return std::ptr::eq(named.name().to_untyped(), node.get());
    }

    if let Some(for_loop) = parent.cast::<ast::ForLoop>() {
        return !std::ptr::eq(for_loop.iterable().to_untyped(), node.get());
    }

    matches!(
        parent.kind(),
        SyntaxKind::Params
            | SyntaxKind::Destructuring
            | SyntaxKind::Spread
            | SyntaxKind::ImportItemPath
            | SyntaxKind::RenamedImportItem
    )
}

/// The functions that read a file from a path given as their first argument.
const READERS: &[&str] = &[
    "path",
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
/// `path`, `image`, `read`, the data loading functions, `plugin` and `bibliography` (which takes an
/// array of them too), called by their name or through `std`, unless the file defines its
/// own function by that name; and the paths it imports and includes (packages aside). With
/// the 1-based line and column of each string. They're checked against the component's
/// files when it compiles; paths built at runtime can't be.
pub fn file_paths(source: &Source) -> Vec<(String, usize, usize)> {
    let own = defined_names(source);
    let mut paths = Vec::new();

    // Walked with a stack rather than recursively, since the tree can be deep
    let mut nodes = vec![LinkedNode::new(source.root())];
    while let Some(node) = nodes.pop() {
        let strings: Vec<LinkedNode> = match read_path(&node, &own).or_else(|| imported_path(&node))
        {
            Some(path) if path.kind() == SyntaxKind::Str => vec![path],
            Some(path) if path.kind() == SyntaxKind::Array => path
                .children()
                .filter(|item| item.kind() == SyntaxKind::Str)
                .collect(),
            _ => Vec::new(),
        };

        for string in strings {
            let value = string.cast::<ast::Str>().map(|string| string.get());
            let position = source.lines().byte_to_line_column(string.offset());

            if let (Some(value), Some((line, column))) = (value, position) {
                if !value.starts_with('@') {
                    paths.push((value.to_string(), line + 1, column + 1));
                }
            }
        }

        nodes.extend(node.children());
    }

    paths.sort_by_key(|(_path, line, column)| (*line, *column));
    paths
}

/// The first positional argument of a call to one of the `READERS`, by its name (unless the
/// file defines its own) or through `std`.
fn read_path<'a>(node: &LinkedNode<'a>, own: &[String]) -> Option<LinkedNode<'a>> {
    let call = node.cast::<ast::FuncCall>()?;
    let reader = match call.callee() {
        Expr::Ident(callee) if !own.iter().any(|name| name == callee.as_str()) => {
            callee.get().clone()
        }
        Expr::FieldAccess(access) if matches!(access.target(), Expr::Ident(target) if target.as_str() == "std") => {
            access.field().get().clone()
        }
        _ => return None,
    };

    if !READERS.contains(&reader.as_str()) {
        return None;
    }

    let args = node
        .children()
        .find(|child| child.kind() == SyntaxKind::Args)?;
    args.children()
        .find(|child| matches!(child.cast::<ast::Arg>(), Some(ast::Arg::Pos(_))))
}

/// The path an import or include reads, when it's a string.
fn imported_path<'a>(node: &LinkedNode<'a>) -> Option<LinkedNode<'a>> {
    if !matches!(
        node.kind(),
        SyntaxKind::ModuleImport | SyntaxKind::ModuleInclude
    ) {
        return None;
    }

    node.children()
        .find(|child| child.kind() == SyntaxKind::Str)
}

/// The names the file binds itself, with `let` (as a variable or a function) or an import,
/// wherever they are: a call by one of them isn't the standard library's.
fn defined_names(source: &Source) -> Vec<String> {
    let mut names = Vec::new();

    let mut nodes = vec![source.root()];
    while let Some(node) = nodes.pop() {
        if let Some(binding) = node.cast::<ast::LetBinding>() {
            names.extend(
                binding
                    .kind()
                    .bindings()
                    .iter()
                    .map(|ident| ident.get().to_string()),
            );
        }

        if let Some(import) = node.cast::<ast::ModuleImport>() {
            if let Some(Imports::Items(items)) = import.imports() {
                names.extend(items.iter().map(|item| item.bound_name().get().to_string()));
            }
        }

        nodes.extend(node.children());
    }

    names
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
            "#import std as s",
            // `sys` used other than to read one of its fields
            "#let a() = (sys).inputs",
            "#let a() = {sys}.inputs",
            "#import (sys): inputs",
            "#let s = sys",
            "#let a() = dictionary(sys).inputs",
            "#let a() = (std.sys).inputs",
            "#let a() = f(sys)",
            "#let a() = (x: sys)",
        ] {
            let problems = problems(text);
            assert_eq!(problems.len(), 1, "{text}: {problems:?}");
            assert_eq!(problems[0].2, INPUTS, "{text}");
        }

        // In math, where every `std` and `sys` is refused, since math doesn't read fields the
        // way code does
        for (text, message) in [
            ("#let a() = $sys.inputs.assigns$", INPUTS),
            ("#let a() = $std.sys.inputs.assigns.secret$", INPUTS),
            ("#let a() = $eval(\"1\")$", EVAL),
        ] {
            let problems = problems(text);
            assert!(!problems.is_empty(), "{text}");
            assert!(
                problems.iter().all(|problem| problem.2 == message),
                "{text}: {problems:?}"
            );
        }

        for text in [
            "#import sys",
            "#import sys: version",
            "#import std: sys",
            "#import std: *",
            "#let a = sys.version",
            "#let a = std.sys.version",
            "#let pow = std.calc.pow(2, 3)",
            "#let inputs = (a: 1)\n#let b = inputs.a",
            "#let a(x) = x.inputs",
            "#let a(x) = x.sys + x.eval",
            "#let a = (sys: 1, eval: 2)",
            "#let a(sys: none) = 1",
        ] {
            assert_eq!(problems(text), vec![], "{text}");
        }
    }

    #[test]
    fn refuses_eval() {
        for text in [
            "#let a() = eval(\"sys.inputs\")",
            "#let a() = std.eval(\"1\")",
            "#let e = eval",
            "#import std: eval",
        ] {
            let problems = problems(text);
            assert_eq!(problems.len(), 1, "{text}: {problems:?}");
            assert_eq!(problems[0].2, EVAL, "{text}");
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
#import "stamp/helpers.typ": helper
#import "@preview/oxifmt:1.0.0": strfmt
#let page = std.image("stamp/page.png")
#let mark = image(path("stamp/mark.svg"))
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
                ("stamp/helpers.typ".to_string(), (7, 9)),
                ("stamp/page.png".to_string(), (9, 23)),
                ("stamp/mark.svg".to_string(), (10, 24)),
            ]
        );
    }

    #[test]
    fn leaves_out_calls_to_the_files_own_functions() {
        let text = "#let image(name) = name\n#import \"x.typ\": read\n#let a = image(\"check\") + read(\"key\")\n#let b = std.image(\"real.png\")\n";
        let paths: Vec<_> = file_paths(&Source::detached(text))
            .into_iter()
            .map(|(path, _, _)| path)
            .collect();

        assert_eq!(paths, vec!["x.typ".to_string(), "real.png".to_string()]);
    }

    #[test]
    fn reports_syntax_errors_rather_than_the_other_rules() {
        let errors = errors(&Source::detached("Hello\n#let a = (\n"));

        assert!(!errors.is_empty());
        assert!(errors.iter().all(|error| error.message != TOP_LEVEL));
    }
}
