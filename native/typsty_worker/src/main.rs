//! Renders Typst documents for `Typsty.Pool`, in a process of its own, so that a render
//! that runs too long or uses too much memory can be stopped by ending the process, without
//! affecting the BEAM.
//!
//! The pool starts it as a port, with `{:packet, 4}` framing: each request on stdin, and
//! each response on stdout, is a 4-byte big-endian length followed by a term in Erlang's
//! external term format. Requests are rendered one at a time:
//!
//! - request: `{:render, template, assigns, files, options}`, with the assigns as
//!   `Typsty.Value` builds them for the NIF, the options the NIF takes, and a `:timeout` in
//!   milliseconds or `nil`
//! - response: what the NIF sends or returns: `{:ok, output, warnings}`,
//!   `{:error, :typst, diagnostics}`, `{:error, :crashed, message}`, or
//!   `{:error, :invalid, message}` for invalid arguments
//!
//! Each request is acknowledged with `:started` as soon as it's read, before its response.
//!
//! A frame that isn't a term ends the worker (exit status 87): the pool and the worker
//! disagree on where frames start, and nothing that follows can be trusted. The worker also
//! exits (status 0) after a render panicked, and when Typst's table of file paths is nearly
//! full, so that the pool replaces it.
//!
//! The process ends, with an exit status the pool understands, when a render runs past its
//! timeout or the process goes over its memory limit (`--memory-limit BYTES`). Problems are
//! reported on stderr. Responses are written to the stdout the process started with, and
//! stdout itself is pointed at stderr before the first request, so that anything else that
//! prints (usvg prints warnings about some fonts with `println!`) can't break their framing.
//!
//! `typsty_worker --check` starts up as a worker would, prints the protocol version and
//! exits, for the pool to check that the worker can run before starting any.

mod etf;
mod memory;
mod value;

use std::fs::File;
use std::io::{self, BufWriter, Read, Write};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use etf::Term;
use typsty_core::isolate::{self, Interrupted};
use typsty_core::{
    Diagnostic, FontSettings, Format, Output, PrepareError, RenderJob, Rendered, Severity,
};

#[global_allocator]
static ALLOCATOR: memory::Limited = memory::Limited;

/// The version of the protocol between the pool and the worker, which `--check` prints. The
/// pool refuses a worker that speaks another version.
const PROTOCOL_VERSION: u32 = 1;

/// The exit statuses `Typsty.Pool` understands.
pub mod exit {
    /// The process went over its memory limit.
    pub const MEMORY_LIMIT: i32 = 85;
    /// A render ran past its timeout.
    pub const TIMEOUT: i32 = 86;
    /// The worker was started wrongly, or a request couldn't be read.
    pub const PROTOCOL: i32 = 87;

    /// Ends the process right away, without unwinding or running exit handlers: other
    /// threads may still be rendering, and nothing may allocate when the memory limit is
    /// reached.
    pub fn now(status: i32) -> ! {
        unsafe { libc::_exit(status) }
    }
}

struct Arguments {
    memory_limit: usize,
    check: bool,
}

fn main() {
    let arguments = match parse_args(std::env::args().skip(1)) {
        Ok(arguments) => arguments,
        Err(message) => {
            eprintln!("typsty_worker: {message}");
            exit::now(exit::PROTOCOL);
        }
    };

    memory::set_limit(arguments.memory_limit);

    // A crash here only ends this process, so documents may read files that are unsafe to
    // decode inside the BEAM, such as PDF files (see `typsty_core::checks`)
    typsty_core::init(typsty_core::Config { isolated: true });

    if arguments.check {
        println!("typsty_worker {PROTOCOL_VERSION}");
        return;
    }

    let responses = take_stdout().unwrap_or_else(|error| {
        eprintln!("typsty_worker: couldn't set up its output: {error}");
        exit::now(exit::PROTOCOL);
    });

    // Requests are read on a thread of their own, so that the worker notices right away when
    // the pool closes the port, even in the middle of a render, and exits. Closing the port
    // is how the pool stops a render, and it also happens when the process using the worker
    // dies, when the pool shuts down and when the VM exits, so the worker never outlives it.
    let (requests, received) = mpsc::sync_channel::<Vec<u8>>(0);
    std::thread::Builder::new()
        .name("typsty-requests".into())
        .spawn(move || read_requests(requests))
        .unwrap_or_else(|_| exit::now(exit::PROTOCOL));

    // The memory in use after the caches were last cleared (see `trim_caches`)
    let mut floor = memory::used();

    for request in received {
        // Acknowledges the request before working on it, so that the pool can tell a worker
        // that died before it got the request (whose render can go to another worker) from
        // one that died during the render
        if write_response(&responses, &Term::atom("started")).is_err() {
            exit::now(exit::PROTOCOL);
        }

        let Handled {
            mut response,
            retire,
        } = handle(request);

        // A frame's length is 4 bytes
        if etf::frame_length(&response) > u32::MAX as usize {
            response = error(
                Term::atom("crashed"),
                Term::binary("the rendered document is larger than 4 GiB, the most a Typsty.Pool worker can return"),
            );
        }

        if write_response(&responses, &response).is_err() {
            // The pool is gone
            exit::now(exit::PROTOCOL);
        }

        drop(response);
        trim_caches(&mut floor);

        // The pool replaces a worker that exits while it's idle. A worker that panicked may
        // have been left in a bad state, and one whose table of file paths is nearly full
        // would refuse new paths for good (see `typsty_core::world`)
        if retire
            || typsty_core::world::file_ids_running_out()
            || typsty_core::world::given_paths_running_out()
        {
            exit::now(0);
        }
    }
}

fn write_response(responses: &File, response: &Term) -> io::Result<()> {
    let mut output = BufWriter::new(responses);
    etf::write_frame(response, &mut output)?;
    output.flush()
}

/// Takes the process's stdout for responses, and points stdout at stderr, where anything
/// else that prints goes from then on.
#[cfg(unix)]
fn take_stdout() -> io::Result<File> {
    use std::os::fd::AsFd;

    let responses = File::from(io::stdout().as_fd().try_clone_to_owned()?);

    // SAFETY: dup2 points file descriptor 1 at stderr's file, in one step. Responses have a
    // descriptor of their own, so nothing depends on what descriptor 1 was
    if unsafe { libc::dup2(libc::STDERR_FILENO, libc::STDOUT_FILENO) } == -1 {
        return Err(io::Error::last_os_error());
    }

    Ok(responses)
}

/// Takes the process's stdout for responses, and points stdout at stderr, where anything
/// else that prints goes from then on. (Rust looks the standard handles up for every write.)
#[cfg(windows)]
fn take_stdout() -> io::Result<File> {
    use std::os::windows::io::{AsHandle, AsRawHandle, RawHandle};

    #[link(name = "kernel32")]
    extern "system" {
        fn SetStdHandle(std_handle: u32, handle: RawHandle) -> i32;
    }

    // (DWORD)-11
    const STD_OUTPUT_HANDLE: u32 = -11i32 as u32;

    let responses = File::from(io::stdout().as_handle().try_clone_to_owned()?);

    // SAFETY: SetStdHandle only changes which handle the process's standard output is.
    // Stderr's handle stays open for the life of the process, and responses have a handle of
    // their own
    if unsafe { SetStdHandle(STD_OUTPUT_HANDLE, io::stderr().as_raw_handle()) } == 0 {
        return Err(io::Error::last_os_error());
    }

    Ok(responses)
}

fn read_requests(requests: mpsc::SyncSender<Vec<u8>>) {
    let mut input = io::stdin().lock();

    loop {
        match read_frame(&mut input) {
            Ok(Some(request)) => {
                if requests.send(request).is_err() {
                    exit::now(exit::PROTOCOL);
                }
            }
            // The pool closed the port
            Ok(None) => exit::now(0),
            Err(error) => {
                eprintln!("typsty_worker: couldn't read a request: {error}");
                exit::now(exit::PROTOCOL);
            }
        }
    }
}

fn parse_args(mut args: impl Iterator<Item = String>) -> Result<Arguments, String> {
    let mut arguments = Arguments {
        memory_limit: 0,
        check: false,
    };

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--memory-limit" => {
                arguments.memory_limit = args
                    .next()
                    .and_then(|value| value.parse().ok())
                    .ok_or("--memory-limit needs a number of bytes")?;
            }
            "--check" => arguments.check = true,
            other => return Err(format!("unknown argument: {other}")),
        }
    }

    Ok(arguments)
}

fn read_frame(input: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
    // The end of the input between frames means the pool closed the port; inside one, that
    // the worker and the pool disagree on where frames start
    let mut length = [0; 4];
    let mut read = 0;
    while read < length.len() {
        match input.read(&mut length[read..]) {
            Ok(0) if read == 0 => return Ok(None),
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(count) => read += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    let length = u32::from_be_bytes(length) as usize;

    // A request that can't fit under the memory limit is read to its end, so that the pool
    // finishes sending it and sees the exit status, rather than a broken pipe
    if let Some(limit) = memory::limit() {
        if length > limit.saturating_sub(memory::used()) {
            io::copy(&mut input.take(length as u64), &mut io::sink())?;
            exit::now(exit::MEMORY_LIMIT);
        }
    }

    let mut frame = vec![0; length];
    input.read_exact(&mut frame)?;
    Ok(Some(frame))
}

/// Typst's caches speed up later renders, but count against the memory limit. Once they take
/// half of the room left under the limit, they're dropped, so that the next render has room.
/// What's left after dropping them (the fonts Typst has loaded, mostly) is the new floor.
fn trim_caches(floor: &mut usize) {
    let Some(limit) = memory::limit() else {
        return;
    };

    if memory::used() > *floor + limit.saturating_sub(*floor) / 2 {
        typsty_core::render::clear_caches();
        *floor = memory::used();
    }
}

/// A request's response, and whether the worker should exit after sending it.
struct Handled {
    response: Term,
    retire: bool,
}

impl From<Term> for Handled {
    fn from(response: Term) -> Self {
        Self {
            response,
            retire: false,
        }
    }
}

fn handle(request: Vec<u8>) -> Handled {
    let decoded = etf::decode(&request);
    // The request's files were copied out of it
    drop(request);

    // A frame that isn't a term means the worker and the pool disagree on where frames
    // start: whatever comes next can't be trusted
    let decoded = match decoded {
        Ok(decoded) => decoded,
        Err(error) => {
            eprintln!("typsty_worker: {error}");
            exit::now(exit::PROTOCOL);
        }
    };

    let (job, timeout) = match parse_request(decoded) {
        Ok(request) => request,
        Err(message) => return error(Term::atom("invalid"), Term::binary(message)).into(),
    };

    let job = match job.prepare() {
        Ok(job) => job,
        Err(PrepareError::Invalid(message)) => {
            return error(Term::atom("invalid"), Term::binary(message)).into()
        }
        Err(PrepareError::Refused(message)) => {
            return error(
                Term::atom("typst"),
                diagnostics_term(vec![Diagnostic::error(message)]),
            )
            .into()
        }
    };

    let deadline = timeout.map(|timeout| Instant::now() + timeout);
    let (sender, results) = mpsc::sync_channel(1);

    let started = isolate::start(
        1,
        move |cancellation| job.render(cancellation),
        move |result| {
            let _ = sender.send(result);
        },
    );

    if let Err(message) = started {
        return error(Term::atom("crashed"), Term::binary(message)).into();
    }

    let ended = || {
        Err(Interrupted::Panicked(
            "the render ended without a result".into(),
        ))
    };
    let result = match deadline {
        Some(deadline) => {
            match results.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                Ok(result) => result,
                // The render is still running: ending the process is the only way to stop it
                Err(mpsc::RecvTimeoutError::Timeout) => exit::now(exit::TIMEOUT),
                Err(mpsc::RecvTimeoutError::Disconnected) => ended(),
            }
        }
        None => results.recv().unwrap_or_else(|_| ended()),
    };

    match result {
        Ok(Ok(rendered)) => ok(rendered).into(),
        Ok(Err(errors)) => error(Term::atom("typst"), diagnostics_term(errors)).into(),
        Err(Interrupted::Stopped(message)) => error(
            Term::atom("typst"),
            diagnostics_term(vec![Diagnostic::error(message)]),
        )
        .into(),
        Err(interrupted @ Interrupted::Panicked(_)) => Handled {
            response: error(Term::atom("crashed"), Term::binary(interrupted.message())),
            retire: true,
        },
        Err(interrupted) => {
            error(Term::atom("crashed"), Term::binary(interrupted.message())).into()
        }
    }
}

/// Reads a request, taking its binaries out of it rather than copying them.
fn parse_request(term: Term) -> Result<(RenderJob, Option<Duration>), String> {
    let invalid = || "invalid request".to_string();

    let Term::Tuple(elements) = term else {
        return Err(invalid());
    };
    let Ok([Term::Atom(tag), template, assigns, files, Term::Map(options)]) =
        <[Term; 5]>::try_from(elements)
    else {
        return Err(invalid());
    };
    if tag != "render" {
        return Err(invalid());
    }

    let option = |name: &str| {
        options
            .iter()
            .find(|(key, _)| key.as_atom() == Some(name))
            .map(|(_, value)| value)
            .ok_or_else(|| format!("invalid request: missing option {name}"))
    };

    let format = option("format")?
        .as_atom()
        .and_then(Format::from_name)
        .ok_or("invalid request: unknown format")?;

    let Term::Map(fonts) = option("fonts")? else {
        return Err(invalid());
    };
    let font = |name: &str| {
        fonts
            .iter()
            .find(|(key, _)| key.as_atom() == Some(name))
            .map(|(_, value)| value)
            .ok_or_else(invalid)
    };

    let Term::List(files) = files else {
        return Err(invalid());
    };
    let files = files
        .into_iter()
        .map(|file| match file {
            Term::Tuple(pair) => match <[Term; 2]>::try_from(pair) {
                Ok([path, Term::Binary(bytes)]) => Ok((string(&path)?, bytes)),
                _ => Err(invalid()),
            },
            _ => Err(invalid()),
        })
        .collect::<Result<_, _>>()?;

    let timeout = match option("timeout")? {
        Term::Integer(milliseconds) if *milliseconds > 0 => {
            Some(Duration::from_millis(*milliseconds as u64))
        }
        term if term.as_atom() == Some("nil") => None,
        _ => return Err(invalid()),
    };

    let job = RenderJob {
        template: string(&template)?,
        assigns: value::to_dict(&assigns)?,
        files,
        format,
        root: optional_string(option("root")?)?,
        package_paths: strings(option("package_paths")?)?,
        fonts: FontSettings::new(
            strings(font("font_paths")?)?,
            boolean(font("system_fonts")?)?,
            boolean(font("embedded_fonts")?)?,
        ),
        ppi: number(option("ppi")?)?,
        pdf_standards: strings(option("pdf_standards")?)?,
    };

    Ok((job, timeout))
}

fn string(term: &Term) -> Result<String, String> {
    match term {
        Term::Binary(bytes) => String::from_utf8(bytes.clone())
            .map_err(|_| "invalid request: a string isn't valid UTF-8".into()),
        _ => Err("invalid request: expected a string".into()),
    }
}

fn optional_string(term: &Term) -> Result<Option<String>, String> {
    match term.as_atom() {
        Some("nil") => Ok(None),
        _ => string(term).map(Some),
    }
}

fn strings(term: &Term) -> Result<Vec<String>, String> {
    match term {
        Term::List(items) => items.iter().map(string).collect(),
        _ => Err("invalid request: expected a list of strings".into()),
    }
}

fn boolean(term: &Term) -> Result<bool, String> {
    match term.as_atom() {
        Some("true") => Ok(true),
        Some("false") => Ok(false),
        _ => Err("invalid request: expected a boolean".into()),
    }
}

fn number(term: &Term) -> Result<f64, String> {
    match term {
        Term::Float(float) => Ok(*float),
        Term::Integer(integer) => Ok(*integer as f64),
        _ => Err("invalid request: expected a number".into()),
    }
}

fn ok((output, warnings): Rendered) -> Term {
    let output = match output {
        Output::Pdf(bytes) => Term::Binary(bytes),
        Output::Pages(pages) => Term::List(pages.into_iter().map(Term::Binary).collect()),
    };

    Term::Tuple(vec![Term::atom("ok"), output, diagnostics_term(warnings)])
}

fn error(reason: Term, details: Term) -> Term {
    Term::Tuple(vec![Term::atom("error"), reason, details])
}

fn diagnostics_term(diagnostics: Vec<Diagnostic>) -> Term {
    Term::List(diagnostics.into_iter().map(diagnostic_term).collect())
}

/// A `%Typsty.Diagnostic{}` struct, as the NIF returns it.
fn diagnostic_term(diagnostic: Diagnostic) -> Term {
    let severity = match diagnostic.severity {
        Severity::Error => "error",
        Severity::Warning => "warning",
    };

    let trace = diagnostic
        .trace
        .into_iter()
        .map(|point| {
            Term::Map(vec![
                (Term::atom("message"), Term::binary(point.message)),
                (Term::atom("file"), optional(point.file.map(Term::binary))),
                (Term::atom("line"), optional(point.line.map(integer))),
                (Term::atom("column"), optional(point.column.map(integer))),
            ])
        })
        .collect();

    Term::Map(vec![
        (
            Term::atom("__struct__"),
            Term::atom("Elixir.Typsty.Diagnostic"),
        ),
        (Term::atom("severity"), Term::atom(severity)),
        (Term::atom("message"), Term::binary(diagnostic.message)),
        (
            Term::atom("hints"),
            Term::List(diagnostic.hints.into_iter().map(Term::binary).collect()),
        ),
        (
            Term::atom("file"),
            optional(diagnostic.file.map(Term::binary)),
        ),
        (Term::atom("line"), optional(diagnostic.line.map(integer))),
        (
            Term::atom("column"),
            optional(diagnostic.column.map(integer)),
        ),
        (Term::atom("trace"), Term::List(trace)),
    ])
}

fn integer(value: usize) -> Term {
    Term::Integer(value as i64)
}

fn optional(term: Option<Term>) -> Term {
    term.unwrap_or_else(Term::nil)
}
