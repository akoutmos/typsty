# ecow 0.2.6, patched for Typsty

This is ecow 0.2.6 from crates.io (https://github.com/typst/ecow, MIT OR Apache-2.0), used
through `[patch.crates-io]` in `native/Cargo.toml`, with one change in `src/vec.rs`:
`EcoVec::grow` panics when an allocation would be larger than 1 GiB, before it changes
anything, the way it already panics for a capacity past `isize::MAX`.

Typst's strings and arrays are `EcoString`s and `EcoVec`s. A template that repeats a string
or an array, or builds a range, a number of times that comes from its data (`"x" * n`, or
`qty * price` when an attacker sends a string as `qty`) would otherwise ask for as much
memory as the number says, and a failed allocation aborts the process: for Typsty's NIF,
the whole BEAM. Typsty catches the panic and returns it as an error.

Remove this directory and the patch when that's no longer needed.
