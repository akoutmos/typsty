# codex 0.3.0, patched for Typsty

This is codex 0.3.0 from crates.io (https://github.com/typst/codex, Apache-2.0), used through
`[patch.crates-io]` in `native/Cargo.toml`, with one change in `src/numeral_systems.rs`:
`NumeralSystem::represent` returns `RepresentationError::TooLarge` when an additive system
(Roman, Greek, Armenian, Hebrew numerals) or a symbolic one (`*`) would repeat its largest
symbol more than 1,000 times. Without it, numbering a large number from a template's data
(`enum(start: assigns.n, numbering: "I.")`, or a page counter) writes n / 1,000,000 symbols,
which takes unbounded time and memory and can't be cancelled. Typst falls back to Arabic
numerals, with a warning, for numbers a system can't represent.

Remove this directory and the patch when Typst uses a codex that bounds these systems.
