# Patches for upstream

Changes to Typst's dependencies that would make rendering documents with untrusted data
safer, to offer upstream. Typsty doesn't apply them: it builds with the published crates,
and renders that need the protection these give should run in a `Typsty.Pool`. They aren't
part of the Hex package.

Each is a `git format-patch` file made against the commit the published crate was built
from (in its `.cargo_vcs_info.json`), with tests, and applies with `git am`.

## codex-bound-repeated-numerals.patch

For [typst/codex](https://github.com/typst/codex), against 0.3.0
(`ed6d7a8e8cec7cca53d75656412aa32a43f1111a`).

Additive numeral systems (Roman, Greek, Armenian, Hebrew) and the symbolic one (`*`, `†`,
...) write a symbol for every multiple of their largest value, so `numbering("I", n)` with
a huge `n` from a document's data takes unbounded time and memory, which can't be
interrupted. The patch makes `represent` return `TooLarge` past 10,000 repetitions, and
Typst then falls back to Arabic numerals with a warning. The bound leaves everything codex's
tests check (up to 50,000) as it was.

## ecow-limit-allocations.patch

For [typst/ecow](https://github.com/typst/ecow), against 0.2.6
(`72875f7d1ee363c1d68c9717b4d6ca303e5119f9`).

Typst's strings and arrays are ecow's, and a document can ask for one of any size (`"x" * n`,
`range(n)`, or `qty * price` when a string is passed as `qty`). A failed allocation aborts the
process. The patch makes `EcoVec::grow` panic past 1 GiB instead, the way it already panics
on a capacity overflow, so that applications that catch panics can report an error.

The 1 GiB limit is a policy choice, which upstream may prefer to make configurable, or to
enforce in Typst itself (in `Str::repeat`, `Array::repeat` and `range`) rather than in ecow.
