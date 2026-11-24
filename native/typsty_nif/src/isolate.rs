//! Runs Typst away from the BEAM's scheduler threads.
//!
//! Dirty schedulers have small stacks (320 KiB by default), and Typst recurses deeply when
//! it parses, evaluates and lays out nested content, values and SVGs. A stack overflow can't
//! be caught: it kills the whole VM. So the work runs on a thread of its own with a large
//! stack, and Typst's thread pool gets large stacks too.
//!
//! Running on a separate thread also turns panics into errors, and lets the NIF stop waiting
//! after a timeout, so that a render that runs too long doesn't hold a scheduler.
//!
//! A thread can't be killed safely (it would leave Typst's caches and the allocator locked),
//! so a render that times out is cancelled cooperatively instead: the cancellation flag is
//! set, and the render unwinds the next time Typst calls into its `World` (see
//! `Cancellation::check`). Typst calls the world constantly while it lays out documents and
//! loads files and fonts, and whenever it checks a memoized result. Pure computation in a
//! template (a long loop that only does arithmetic) doesn't, so it runs until it reaches
//! the next call into the world.

use std::any::Any;
use std::panic::{catch_unwind, resume_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// The stack size of the threads that run Typst. This is reserved address space: memory is
/// only used as the stack actually grows.
pub const STACK_SIZE: usize = 256 * 1024 * 1024;

pub enum Failure {
    /// The work panicked, with the panic's message.
    Panicked(String),
    /// The work didn't finish in time, and was cancelled.
    TimedOut(Duration),
    /// The render couldn't start in time, because the limit of renders running at once was
    /// reached.
    Busy { timeout: Duration, limit: usize },
    /// The thread couldn't be started.
    Spawn(String),
}

impl Failure {
    pub fn message(&self) -> String {
        match self {
            Failure::Panicked(message) => format!("Typst crashed (it panicked with: {message})"),
            Failure::TimedOut(timeout) => format!(
                "rendering didn't finish within the timeout ({} ms), and was cancelled",
                timeout.as_millis()
            ),
            Failure::Busy { timeout, limit } => format!(
                "rendering didn't start within the timeout ({} ms): {limit} renders were already running (the :max_concurrent_renders limit), counting renders that timed out and are still being cancelled",
                timeout.as_millis()
            ),
            Failure::Spawn(error) => format!("couldn't start a thread to render on: {error}"),
        }
    }
}

/// The number of renders running, including renders that timed out and are still being
/// cancelled. A cancelled render only stops at its next call into the world, so without a
/// limit, renders that keep timing out could pile up in the background.
static RENDERS: Mutex<usize> = Mutex::new(0);
static RENDER_FINISHED: Condvar = Condvar::new();

pub fn running_renders() -> usize {
    *RENDERS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// A render's place among the renders running at once, given back when its work ends.
struct RenderSlot;

impl RenderSlot {
    /// Waits for fewer than `limit` renders to be running, until the deadline.
    fn acquire(limit: usize, deadline: Option<Instant>) -> Option<RenderSlot> {
        let mut running = RENDERS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        while *running >= limit.max(1) {
            running = match deadline {
                None => RENDER_FINISHED
                    .wait(running)
                    .unwrap_or_else(|poisoned| poisoned.into_inner()),
                Some(deadline) => {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        return None;
                    }

                    RENDER_FINISHED
                        .wait_timeout(running, remaining)
                        .unwrap_or_else(|poisoned| poisoned.into_inner())
                        .0
                }
            };
        }

        *running += 1;
        Some(RenderSlot)
    }
}

impl Drop for RenderSlot {
    fn drop(&mut self) {
        *RENDERS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) -= 1;
        RENDER_FINISHED.notify_one();
    }
}

/// A flag the NIF sets when it stops waiting for a render.
#[derive(Clone, Default)]
pub struct Cancellation(Arc<AtomicBool>);

/// The panic payload a cancelled render unwinds with.
struct Cancelled;

impl Cancellation {
    fn cancel(&self) {
        self.0.store(true, Ordering::Relaxed);
    }

    /// Unwinds the render if it was cancelled. Unwinding is safe here: it only runs at the
    /// start of a `World` method, before any of the world's locks are taken, and the locks
    /// Typst holds while calling the world (comemo's) are released as the stack unwinds.
    /// `resume_unwind` skips the panic hook, so nothing is reported.
    pub fn check(&self) {
        if self.0.load(Ordering::Relaxed) {
            resume_unwind(Box::new(Cancelled));
        }
    }
}

/// Runs the work on a new thread with a large stack, and waits for it, up to the timeout.
/// When it times out, the work's cancellation is set.
///
/// Work with a `limit` is a render: it first waits (within the timeout) until fewer than
/// `limit` renders are running, and counts as running until its work actually ends.
pub fn run<T, F>(timeout: Option<Duration>, limit: Option<usize>, work: F) -> Result<T, Failure>
where
    T: Send + 'static,
    F: FnOnce(Cancellation) -> T + Send + 'static,
{
    let deadline = timeout.map(|timeout| Instant::now() + timeout);

    let slot = match limit {
        Some(limit) => Some(RenderSlot::acquire(limit, deadline).ok_or(Failure::Busy {
            timeout: timeout.unwrap_or_default(),
            limit,
        })?),
        None => None,
    };

    let (sender, receiver) = mpsc::sync_channel(1);
    let cancellation = Cancellation::default();
    let worker_cancellation = cancellation.clone();

    std::thread::Builder::new()
        .name("typsty".into())
        .stack_size(STACK_SIZE)
        .spawn(move || {
            // The slot is given back when the work ends, even if the NIF stopped waiting
            let _slot = slot;
            let result =
                catch_unwind(AssertUnwindSafe(|| work(worker_cancellation))).map_err(panic_message);
            // The receiver is gone if the NIF stopped waiting after a timeout
            let _ = sender.send(result);
        })
        .map_err(|error| Failure::Spawn(error.to_string()))?;

    let received = match (timeout, deadline) {
        (Some(timeout), Some(deadline)) => {
            let remaining = deadline.saturating_duration_since(Instant::now());
            receiver
                .recv_timeout(remaining)
                .map_err(|error| match error {
                    mpsc::RecvTimeoutError::Timeout => {
                        cancellation.cancel();
                        Failure::TimedOut(timeout)
                    }
                    mpsc::RecvTimeoutError::Disconnected => Failure::Panicked("unknown".into()),
                })?
        }
        _ => receiver
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
            if !payload.is::<Cancelled>() {
                eprintln!(
                    "[Typsty] a Typst background job panicked: {}",
                    panic_message(payload)
                );
            }
        })
        .build_global();
}

fn panic_message(payload: Box<dyn Any + Send>) -> String {
    if payload.is::<Cancelled>() {
        "cancelled".into()
    } else if let Some(message) = payload.downcast_ref::<&str>() {
        message.to_string()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "unknown".into()
    }
}
