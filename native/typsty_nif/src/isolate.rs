//! Runs Typst away from the BEAM's scheduler threads.
//!
//! Dirty schedulers have small stacks (320 KiB by default), and Typst recurses deeply when
//! it parses, evaluates and lays out nested content, values and SVGs. A stack overflow can't
//! be caught: it kills the whole VM. So the work runs on a thread of its own with a large
//! stack, and Typst's thread pool gets large stacks too.
//!
//! Running on a separate thread also turns panics into errors, and lets the NIF give up
//! waiting after a timeout, so that a render that never finishes doesn't hold a scheduler
//! forever. The render itself can't be stopped: it keeps running until it finishes.

use std::any::Any;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::mpsc;
use std::time::Duration;

/// The stack size of the threads that run Typst. This is reserved address space: memory is
/// only used as the stack actually grows.
pub const STACK_SIZE: usize = 256 * 1024 * 1024;

pub enum Failure {
    /// The work panicked, with the panic's message.
    Panicked(String),
    /// The work didn't finish in time. It keeps running in the background.
    TimedOut(Duration),
    /// The thread couldn't be started.
    Spawn(String),
}

impl Failure {
    pub fn message(&self) -> String {
        match self {
            Failure::Panicked(message) => format!("Typst crashed (it panicked with: {message})"),
            Failure::TimedOut(timeout) => format!(
                "rendering didn't finish within the timeout ({} ms). It keeps running in the background until it finishes",
                timeout.as_millis()
            ),
            Failure::Spawn(error) => format!("couldn't start a thread to render on: {error}"),
        }
    }
}

/// Runs the work on a new thread with a large stack, and waits for it, up to the timeout.
pub fn run<T, F>(timeout: Option<Duration>, work: F) -> Result<T, Failure>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    let (sender, receiver) = mpsc::sync_channel(1);

    std::thread::Builder::new()
        .name("typsty".into())
        .stack_size(STACK_SIZE)
        .spawn(move || {
            let result = catch_unwind(AssertUnwindSafe(work)).map_err(panic_message);
            // The receiver is gone if the NIF stopped waiting after a timeout
            let _ = sender.send(result);
        })
        .map_err(|error| Failure::Spawn(error.to_string()))?;

    let received = match timeout {
        Some(timeout) => receiver
            .recv_timeout(timeout)
            .map_err(|error| match error {
                mpsc::RecvTimeoutError::Timeout => Failure::TimedOut(timeout),
                mpsc::RecvTimeoutError::Disconnected => Failure::Panicked("unknown".into()),
            })?,
        None => receiver
            .recv()
            .map_err(|_| Failure::Panicked("unknown".into()))?,
    };

    received.map_err(Failure::Panicked)
}

/// Panics in Typst's threads become errors with the panic's message, so the default panic
/// hook's report on stderr is only kept for other threads.
pub fn init_panic_hook() {
    let default_hook = std::panic::take_hook();

    std::panic::set_hook(Box::new(move |info| {
        let ours = std::thread::current()
            .name()
            .is_some_and(|name| name.starts_with("typsty"));

        if !ours {
            default_hook(info);
        }
    }));
}

/// Sets up the global thread pool that Typst lays out pages and the PDF exporter decodes
/// images on, with large stacks. Its default panic handler aborts the process, so panics
/// in its background jobs are only logged instead.
pub fn init_thread_pool() {
    // This fails if the pool was already initialized, which is fine
    let _ = rayon::ThreadPoolBuilder::new()
        .thread_name(|index| format!("typsty-worker-{index}"))
        .stack_size(STACK_SIZE)
        .panic_handler(|payload| {
            eprintln!(
                "[Typsty] a Typst background job panicked: {}",
                panic_message(payload)
            );
        })
        .build_global();
}

fn panic_message(payload: Box<dyn Any + Send>) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        message.to_string()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "unknown".into()
    }
}
