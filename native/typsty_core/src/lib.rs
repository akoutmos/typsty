//! Compiling and exporting Typst documents, for Typsty's NIF (rendering inside the BEAM)
//! and its worker (rendering in a separate OS process, for `Typsty.Pool`).
//!
//! Everything Typst does runs on a thread of its own, with a large stack (see `isolate`).

pub mod checks;
pub mod diagnostics;
pub mod export;
pub mod fonts;
pub mod isolate;
pub mod render;
pub mod values;
pub mod world;

pub use diagnostics::{Diagnostic, Severity, TracePoint};
pub use export::Output;
pub use fonts::FontSettings;
pub use render::{Failure, Format, RenderJob, Rendered};

/// Sets up what the rest of this crate relies on: Typst's thread pool with large stacks, and
/// a panic hook that keeps panics in Typst's threads (which become errors) off stderr. Call
/// it once, before rendering.
pub fn init() {
    isolate::init_panic_hook();
    isolate::init_thread_pool();
}

/// The version of the Typst compiler, such as "0.15.1".
pub fn typst_version() -> String {
    let version = typst::utils::version();
    format!(
        "{}.{}.{}",
        version.major(),
        version.minor(),
        version.patch()
    )
}
