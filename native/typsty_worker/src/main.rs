//! Renders Typst documents for `Typsty.Pool`, in a process of its own, so that a render
//! that runs too long or uses too much memory can be stopped by ending the process, without
//! affecting the BEAM.
//!
//! The pool starts it as a port, with `{:packet, 4}` framing: each request on stdin, and
//! each response on stdout, is a 4-byte big-endian length followed by a term in Erlang's
//! external term format. Requests are rendered one at a time:
//!
//! - request: `{:render, template, variables, files, options}`, with the variables as
//!   `Typsty.Value` builds them for the NIF, and the same options the NIF takes
//! - response: the NIF's results: `{:ok, output, warnings}`, `{:error, diagnostics}` or
//!   `{:error, message}`
//!
//! The process ends, with an exit status the pool understands, when a render runs past its
//! timeout or the process goes over its memory limit (`--memory-limit BYTES`). Stdout only
//! carries responses; problems are reported on stderr.

mod etf;
mod memory;
mod value;

use std::io::{self, Read, Write};
use std::sync::mpsc;
use std::time::Duration;

use etf::Term;
use typsty_core::isolate;
use typsty_core::{Diagnostic, Failure, FontSettings, Format, Output, RenderJob, Severity};

#[global_allocator]
static ALLOCATOR: memory::Limited = memory::Limited;

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

fn main() {
    let memory_limit = match parse_args(std::env::args().skip(1)) {
        Ok(limit) => limit,
        Err(message) => {
            eprintln!("typsty_worker: {message}");
            exit::now(exit::PROTOCOL);
        }
    };

    memory::set_limit(memory_limit);
    typsty_core::init();

    // Requests are read on a thread of their own, so that the worker notices right away when
    // the pool closes the port, even in the middle of a render, and exits. Closing the port
    // is how the pool stops a render, and it also happens when the process using the worker
    // dies, when the pool shuts down and when the VM exits, so the worker never outlives it.
    let (requests, received) = mpsc::sync_channel::<Vec<u8>>(0);
    std::thread::Builder::new()
        .name("typsty-requests".into())
        .spawn(move || read_requests(requests))
        .unwrap_or_else(|_| exit::now(exit::PROTOCOL));

    let mut output = io::stdout().lock();

    for request in received {
        let response = handle(&request);
        drop(request);

        if write_frame(&mut output, &response).is_err() {
            // The pool is gone
            exit::now(exit::PROTOCOL);
        }

        drop(response);
        trim_caches();
    }
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

fn parse_args(mut args: impl Iterator<Item = String>) -> Result<usize, String> {
    let mut memory_limit = 0;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--memory-limit" => {
                memory_limit = args
                    .next()
                    .and_then(|value| value.parse().ok())
                    .ok_or("--memory-limit needs a number of bytes")?;
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }

    Ok(memory_limit)
}

fn read_frame(input: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut length = [0; 4];
    match input.read_exact(&mut length) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }

    let mut frame = vec![0; u32::from_be_bytes(length) as usize];
    input.read_exact(&mut frame)?;
    Ok(Some(frame))
}

fn write_frame(output: &mut impl Write, frame: &[u8]) -> io::Result<()> {
    let length = u32::try_from(frame.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "response too large"))?;

    output.write_all(&length.to_be_bytes())?;
    output.write_all(frame)?;
    output.flush()
}

/// Typst's caches speed up later renders, but count against the memory limit. Once they
/// take half of it, they're dropped, so that the next render has room.
fn trim_caches() {
    if let Some(limit) = memory::limit() {
        if memory::used() > limit / 2 {
            typsty_core::render::clear_caches();
        }
    }
}

fn handle(request: &[u8]) -> Vec<u8> {
    let parsed = etf::decode(request)
        .map_err(|error| error.to_string())
        .and_then(|term| parse_request(&term));

    let response = match parsed {
        Err(message) => error_message(message),
        Ok((job, timeout)) => match job.render(timeout, None) {
            Err(isolate::Failure::TimedOut(_)) => exit::now(exit::TIMEOUT),
            Err(failure) => error_diagnostics(vec![Diagnostic::error(failure.message())]),
            Ok(Ok((output, warnings))) => Term::Tuple(vec![
                Term::atom("ok"),
                output_term(output),
                diagnostics_term(warnings),
            ]),
            Ok(Err(Failure::Invalid(message))) => error_message(message),
            Ok(Err(Failure::Diagnostics(errors))) => error_diagnostics(errors),
        },
    };

    etf::encode(&response)
}

fn parse_request(term: &Term) -> Result<(RenderJob, Option<Duration>), String> {
    let invalid = || "invalid request".to_string();

    let Term::Tuple(elements) = term else {
        return Err(invalid());
    };
    let [Term::Atom(tag), template, variables, files, Term::Map(options)] = elements.as_slice()
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
        .ok_or("unknown format")?;

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

    let files = match files {
        Term::List(files) => files
            .iter()
            .map(|file| match file {
                Term::Tuple(pair) => match pair.as_slice() {
                    [path, Term::Binary(bytes)] => Ok((string(path)?, bytes.clone())),
                    _ => Err(invalid()),
                },
                _ => Err(invalid()),
            })
            .collect::<Result<_, _>>()?,
        _ => return Err(invalid()),
    };

    let job = RenderJob {
        template: string(template)?,
        variables: value::to_dict(variables)?,
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

    let timeout = match option("timeout")? {
        Term::Integer(milliseconds) if *milliseconds > 0 => {
            Some(Duration::from_millis(*milliseconds as u64))
        }
        term if term.as_atom() == Some("nil") => None,
        _ => return Err(invalid()),
    };

    Ok((job, timeout))
}

fn string(term: &Term) -> Result<String, String> {
    match term {
        Term::Binary(bytes) => {
            String::from_utf8(bytes.clone()).map_err(|_| "invalid string".into())
        }
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

fn error_message(message: String) -> Term {
    Term::Tuple(vec![Term::atom("error"), Term::binary(message)])
}

fn error_diagnostics(diagnostics: Vec<Diagnostic>) -> Term {
    Term::Tuple(vec![Term::atom("error"), diagnostics_term(diagnostics)])
}

fn output_term(output: Output) -> Term {
    match output {
        Output::Pdf(bytes) => Term::Binary(bytes),
        Output::Pages(pages) => Term::List(pages.into_iter().map(Term::Binary).collect()),
    }
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
