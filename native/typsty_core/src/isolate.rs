//! Runs Typst away from the BEAM's scheduler threads.
//!
//! Dirty schedulers have small stacks (320 KiB by default), and Typst recurses deeply when
//! it parses, evaluates and lays out nested content, values and SVGs. A stack overflow can't
//! be caught: it kills the whole VM. So each render runs on a thread of its own with a large
//! stack, and Typst's thread pool gets large stacks too. Running on a separate thread also
//! turns panics into errors.
//!
//! Renders are started with `start`, which returns right away: the NIF doesn't wait for the
//! render, so it never holds a scheduler while Typst works. The result is handed to a
//! callback on the render's thread, which the NIF uses to send it to the process that asked
//! for the render. At most a given number of renders run at once; the others wait in a
//! queue, in the order they were started.
//!
//! A thread can't be killed safely (it would leave Typst's caches and the allocator locked),
//! so a render that's abandoned is cancelled cooperatively instead: the cancellation flag is
//! set, and the render unwinds the next time Typst calls into its `World` (see
//! `Cancellation::check`). Typst calls the world constantly while it lays out documents and
//! loads files and fonts, and whenever it checks a memoized result. Pure computation in a
//! template (a long loop that only does arithmetic) doesn't, so it runs until it reaches
//! the next call into the world.

use std::any::Any;
use std::cell::RefCell;
use std::collections::VecDeque;
use std::panic::{catch_unwind, resume_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

/// The stack size of the threads that run Typst. This is reserved address space: memory is
/// only used as the stack actually grows.
pub const STACK_SIZE: usize = 256 * 1024 * 1024;

/// Why a render's work didn't return.
#[derive(Debug)]
pub enum Interrupted {
    /// It panicked: a bug in Typst or in Typsty.
    Panicked(String),
    /// Typsty stopped it, because it went over one of Typsty's limits (see `stop`).
    Stopped(String),
    /// It was cancelled, after it was abandoned.
    Cancelled,
    /// Its thread couldn't be started.
    NoThread(String),
}

impl Interrupted {
    pub fn message(&self) -> String {
        match self {
            Interrupted::Panicked(message) => {
                format!("Typst crashed (it panicked with: {message})")
            }
            Interrupted::Stopped(message) => message.clone(),
            Interrupted::Cancelled => "the render was cancelled".into(),
            Interrupted::NoThread(error) => {
                format!("couldn't start a thread to render on: {error}")
            }
        }
    }
}

/// A flag set when a render is abandoned, which makes it unwind.
#[derive(Clone, Default)]
pub struct Cancellation(Arc<AtomicBool>);

/// The panic payload a cancelled render unwinds with.
struct Cancelled;

/// The panic payload a render that Typsty stops unwinds with.
struct Stopped(String);

impl Cancellation {
    fn cancel(&self) {
        self.0.store(true, Ordering::Relaxed);
    }

    /// Unwinds the render if it was cancelled. This is only called at the start of a `World`
    /// method, while the world holds none of its own locks. The locks Typst holds while it
    /// calls the world (comemo's) are released as the stack unwinds, and nothing is memoized
    /// for the calls that unwind. `resume_unwind` skips the panic hook, so nothing is
    /// reported.
    pub fn check(&self) {
        if self.0.load(Ordering::Relaxed) {
            resume_unwind(Box::new(Cancelled));
        }
    }
}

/// Stops the render running on this thread, with an error. Like `Cancellation::check`, it may
/// only be called where the world holds none of its own locks.
///
/// Typst doesn't stop at every error: errors in show rules and `context` blocks are collected
/// while it goes on laying out the document. Unwinding stops it right away.
pub fn stop(message: String) -> ! {
    resume_unwind(Box::new(Stopped(message)))
}

/// Runs the work, turning panics and unwinding into an `Interrupted`.
fn catch<T>(work: impl FnOnce() -> T) -> Result<T, Interrupted> {
    // A location left by an earlier panic on this thread doesn't belong to this one
    PANIC_LOCATION.with(|cell| cell.borrow_mut().take());

    catch_unwind(AssertUnwindSafe(work)).map_err(|payload| {
        if payload.is::<Cancelled>() {
            return Interrupted::Cancelled;
        }

        match payload.downcast::<Stopped>() {
            Ok(stopped) => Interrupted::Stopped(stopped.0),
            Err(payload) => Interrupted::Panicked(panic_message(payload)),
        }
    })
}

/// Runs quick work on a new thread with a large stack, and waits for it: checking and
/// formatting templates, which can't run for long.
pub fn run<T, W>(work: W) -> Result<T, Interrupted>
where
    T: Send + 'static,
    W: FnOnce() -> T + Send + 'static,
{
    std::thread::Builder::new()
        .name("typsty".into())
        .stack_size(STACK_SIZE)
        .spawn(move || catch(work))
        .map_err(|error| Interrupted::NoThread(error.to_string()))?
        .join()
        .unwrap_or_else(|_| Err(Interrupted::Panicked("unknown".into())))
}

/// How far along a render is, as seen by whoever started it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// Waiting for fewer renders to be running.
    Queued,
    Running,
    /// Its result was handed over.
    Finished,
    /// Given up on, before its result was handed over (see `Ticket::abandon`).
    Abandoned,
}

struct Shared {
    cancellation: Cancellation,
    phase: Mutex<Phase>,
}

/// What `start` returns, to give up on the render.
pub struct Ticket(Arc<Shared>);

impl Ticket {
    /// Gives up on the render, if it hasn't finished: a queued render never starts, and a
    /// running one is cancelled. Its result won't be handed over. Returns the phase the render
    /// was in.
    pub fn abandon(&self) -> Phase {
        let previous = {
            let mut phase = lock(&self.0.phase);
            let previous = *phase;
            if matches!(previous, Phase::Queued | Phase::Running) {
                *phase = Phase::Abandoned;
                self.0.cancellation.cancel();
            }
            previous
        };

        // Frees the memory a queued render holds (its files, for example) right away. The
        // queue is locked after the phase is unlocked: `next_job` locks them the other way
        // around
        if previous == Phase::Queued {
            lock(&QUEUE)
                .waiting
                .retain(|job| !Arc::ptr_eq(&job.shared, &self.0));
        }

        previous
    }
}

/// A render waiting to start.
struct Job {
    shared: Arc<Shared>,
    /// The most renders that may be running for it to start.
    limit: usize,
    /// Runs the render and hands its result over, unless it was abandoned. Given the error
    /// starting its thread failed with, it hands that over instead.
    run: Box<dyn FnOnce(Option<String>) + Send>,
}

struct Queue {
    /// Renders running, including abandoned ones that are still unwinding: a cancelled render
    /// only stops at its next call into the world, so without counting them, renders that
    /// keep timing out could pile up in the background.
    running: usize,
    waiting: VecDeque<Job>,
}

static QUEUE: Mutex<Queue> = Mutex::new(Queue {
    running: 0,
    waiting: VecDeque::new(),
});

/// The number of renders running, including renders that were abandoned and are still
/// being cancelled.
pub fn running_renders() -> usize {
    lock(&QUEUE).running
}

/// Starts a render on a thread of its own, once fewer than `limit` renders are running, and
/// returns right away. `deliver` is called with the result, unless the render was abandoned
/// first, on a thread that isn't the caller's (normally the render's own). It's called while
/// the render's phase is locked, so once `Ticket::abandon` returns `Phase::Finished`,
/// `deliver` has returned.
///
/// Fails if the render could start right away, but its thread couldn't be started.
pub fn start<T, W, D>(limit: usize, work: W, deliver: D) -> Result<Ticket, String>
where
    T: 'static,
    W: FnOnce(Cancellation) -> T + Send + 'static,
    D: FnOnce(Result<T, Interrupted>) + Send + 'static,
{
    let shared = Arc::new(Shared {
        cancellation: Cancellation::default(),
        phase: Mutex::new(Phase::Queued),
    });

    let for_job = shared.clone();
    let run = Box::new(move |spawn_error: Option<String>| {
        let result = match spawn_error {
            None => {
                let cancellation = for_job.cancellation.clone();
                catch(move || work(cancellation))
            }
            Some(error) => Err(Interrupted::NoThread(error)),
        };
        hand_over(&for_job, result, deliver);
    });

    let job = Job {
        shared: shared.clone(),
        limit: limit.max(1),
        run,
    };

    let ready = {
        let mut queue = lock(&QUEUE);
        if queue.waiting.is_empty() && queue.running < job.limit {
            queue.running += 1;
            Some(job)
        } else {
            queue.waiting.push_back(job);
            None
        }
    };

    match ready.map(launch) {
        Some(Launched::Started) => {}
        Some(Launched::Skipped) => {
            lock(&QUEUE).running -= 1;
            launch_waiting(false);
        }
        // This runs on the caller's thread (a scheduler, for the NIF), where a result can't
        // be handed over: the error is returned instead. Renders queued in the meantime are
        // started
        Some(Launched::Failed(_job, error)) => {
            lock(&QUEUE).running -= 1;
            launch_waiting(false);
            return Err(Interrupted::NoThread(error).message());
        }
        // Queued. Slots may be free with renders still waiting, after a thread couldn't be
        // started, so they're started now if they can be
        None => launch_waiting(false),
    }

    Ok(Ticket(shared))
}

/// Hands the result over, unless the render was abandoned. A `deliver` that panics leaves
/// the render abandoned rather than finished, since its result wasn't handed over.
fn hand_over<T>(
    shared: &Shared,
    result: Result<T, Interrupted>,
    deliver: impl FnOnce(Result<T, Interrupted>),
) {
    let mut phase = lock(&shared.phase);
    if *phase != Phase::Abandoned {
        let delivered = catch_unwind(AssertUnwindSafe(|| deliver(result))).is_ok();
        *phase = if delivered {
            Phase::Finished
        } else {
            Phase::Abandoned
        };
    }
}

enum Launched {
    Started,
    /// The job was abandoned while it waited: its slot must be given back.
    Skipped,
    /// The thread couldn't be started, with the error.
    Failed(Job, String),
}

/// Runs a job that has taken one of the running slots, on a new thread, which gives the slot
/// back when it ends.
fn launch(job: Job) -> Launched {
    {
        let mut phase = lock(&job.shared.phase);
        if *phase == Phase::Abandoned {
            return Launched::Skipped;
        }
        *phase = Phase::Running;
    }

    // The thread takes the job, so that the job can be given back if the thread can't start
    let slot = Arc::new(Mutex::new(Some(job)));
    let for_thread = slot.clone();

    let spawned = std::thread::Builder::new()
        .name("typsty".into())
        .stack_size(STACK_SIZE)
        .spawn(move || {
            // Gives the slot back however the render ends
            let _slot = SlotGuard;
            let job = lock(&for_thread).take();
            if let Some(job) = job {
                (job.run)(None);
            }
        });

    match spawned {
        Ok(_handle) => Launched::Started,
        Err(error) => match lock(&slot).take() {
            Some(job) => Launched::Failed(job, error.to_string()),
            None => Launched::Started,
        },
    }
}

struct SlotGuard;

impl Drop for SlotGuard {
    fn drop(&mut self) {
        lock(&QUEUE).running -= 1;
        launch_waiting(true);
    }
}

/// Starts the queued renders that may run now. `deliver_failures` says whether this thread
/// may hand over the failure of a render whose thread can't be started; on a scheduler
/// thread it can't, so the render goes back to the front of the queue, to be retried when
/// another render starts or ends.
fn launch_waiting(deliver_failures: bool) {
    loop {
        let Some(job) = next_job(&mut lock(&QUEUE)) else {
            return;
        };

        match launch(job) {
            Launched::Started => {}
            Launched::Skipped => lock(&QUEUE).running -= 1,
            Launched::Failed(job, error) if deliver_failures => {
                lock(&QUEUE).running -= 1;
                (job.run)(Some(error));
            }
            Launched::Failed(job, _error) => {
                *lock(&job.shared.phase) = Phase::Queued;
                let mut queue = lock(&QUEUE);
                queue.running -= 1;
                queue.waiting.push_front(job);
                return;
            }
        }
    }
}

fn next_job(queue: &mut Queue) -> Option<Job> {
    while let Some(job) = queue.waiting.front() {
        if *lock(&job.shared.phase) == Phase::Abandoned {
            queue.waiting.pop_front();
        } else if queue.running < job.limit {
            queue.running += 1;
            return queue.waiting.pop_front();
        } else {
            return None;
        }
    }

    None
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

thread_local! {
    /// Where the last panic on this thread happened, recorded by the panic hook.
    static PANIC_LOCATION: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// Panics in Typst's threads become errors with the panic's message (see `catch`), so the
/// default panic hook's report on stderr is only kept for other threads.
pub fn init_panic_hook() {
    let default_hook = std::panic::take_hook();

    std::panic::set_hook(Box::new(move |info| {
        let ours = std::thread::current()
            .name()
            .is_some_and(|name| name.starts_with("typsty"));

        if ours {
            let location = info.location().map(ToString::to_string);
            PANIC_LOCATION.with(|cell| *cell.borrow_mut() = location);
        } else {
            default_hook(info);
        }
    }));
}

/// Sets up the global thread pool that Typst lays out pages and the PDF exporter decodes
/// images on, with large stacks. Its default panic handler aborts the process, so panics
/// in its background jobs are only logged instead. A render waiting for such a job could
/// then wait forever, holding its slot; that's a Typst bug either way, and aborting the VM
/// would be worse.
pub fn init_thread_pool() {
    // This fails if the pool was already initialized, which is fine
    let _ = rayon::ThreadPoolBuilder::new()
        .thread_name(|index| format!("typsty-worker-{index}"))
        .stack_size(STACK_SIZE)
        .panic_handler(|payload| {
            if !payload.is::<Cancelled>() && !payload.is::<Stopped>() {
                eprintln!(
                    "[Typsty] a Typst background job panicked: {}",
                    panic_message(payload)
                );
            }
        })
        .build_global();
}

fn panic_message(payload: Box<dyn Any + Send>) -> String {
    let message = if let Some(message) = payload.downcast_ref::<&str>() {
        message.to_string()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "unknown".into()
    };

    match PANIC_LOCATION.with(|cell| cell.borrow_mut().take()) {
        Some(location) => format!("{message}, at {location}"),
        None => message,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    fn run<T: Send + 'static>(
        limit: usize,
        work: impl FnOnce(Cancellation) -> T + Send + 'static,
    ) -> (Ticket, mpsc::Receiver<Result<T, Interrupted>>) {
        let (sender, receiver) = mpsc::channel();
        let ticket = start(limit, work, move |result| {
            let _ = sender.send(result);
        })
        .unwrap();
        (ticket, receiver)
    }

    #[test]
    fn hands_over_results_and_panics() {
        init_panic_hook();

        let (_ticket, receiver) = run(4, |_| 1 + 1);
        assert_eq!(receiver.recv().unwrap().unwrap(), 2);

        let (_ticket, receiver) = run(4, |_| -> () { panic!("boom") });
        let Err(Interrupted::Panicked(message)) = receiver.recv().unwrap() else {
            panic!("expected a panic");
        };
        assert!(message.starts_with("boom, at "), "{message}");

        let (_ticket, receiver) = run(4, |_| -> () { stop("too many files".into()) });
        assert!(matches!(
            receiver.recv().unwrap(),
            Err(Interrupted::Stopped(message)) if message == "too many files"
        ));
    }

    #[test]
    fn queues_renders_over_the_limit_and_abandons_them() {
        // A render that runs until it's cancelled
        let spin = |cancellation: Cancellation| loop {
            cancellation.check();
            std::thread::sleep(Duration::from_millis(1));
        };

        let (first, _first_result) = run(1, spin);
        let (second, second_result) = run(1, |_| "second");

        assert!(second_result
            .recv_timeout(Duration::from_millis(50))
            .is_err());
        assert_eq!(second.abandon(), Phase::Queued);
        assert_eq!(first.abandon(), Phase::Running);

        // The abandoned render's result is never handed over
        assert!(second_result
            .recv_timeout(Duration::from_millis(50))
            .is_err());

        let (third, third_result) = run(1, |_| "third");
        assert_eq!(
            third_result
                .recv_timeout(Duration::from_secs(5))
                .unwrap()
                .unwrap(),
            "third"
        );
        assert_eq!(third.abandon(), Phase::Finished);
    }
}
