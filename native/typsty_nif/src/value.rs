//! Converts the terms built by `Typsty.Value` into Typst values.
//!
//! The Elixir side has already turned atoms into strings, tuples into lists, map keys into
//! strings and structs into plain data, so only these terms reach this module:
//!
//! - `nil`, `true` and `false`
//! - integers, floats and UTF-8 binaries
//! - lists and maps with binary keys
//! - `{:date, year, month, day}`, `{:time, hour, minute, second}`,
//!   `{:datetime, year, month, day, hour, minute, second}` and `{:decimal, string}`

use std::str::FromStr;

use rustler::{MapIterator, Term, TermType};
use typst::foundations::{Array, Datetime, Decimal, Dict, Str, Value};

mod atoms {
    rustler::atoms! {
        nil,
        date,
        time,
        datetime,
        decimal,
    }
}

type Result<T> = std::result::Result<T, String>;

/// How deeply lists and maps may be nested. This conversion runs on a scheduler thread, with
/// a small stack, and Typst also recurses into values when it hashes, compares and prints
/// them. `Typsty.Value` enforces the same limit with a better error message.
pub const MAX_DEPTH: usize = 256;

/// Converts the variables map into a dictionary of Typst values.
pub fn to_dict(term: Term) -> Result<Dict> {
    match to_value(term, 0)? {
        Value::Dict(dict) => Ok(dict),
        _ => Err(invalid("the variables must be a map")),
    }
}

fn to_value(term: Term, depth: usize) -> Result<Value> {
    if depth > MAX_DEPTH {
        return Err(invalid(&format!(
            "lists and maps can be nested at most {MAX_DEPTH} levels deep"
        )));
    }

    match term.get_type() {
        TermType::Atom => {
            if let Ok(boolean) = term.decode::<bool>() {
                Ok(Value::Bool(boolean))
            } else if term == atoms::nil().to_term(term.get_env()) {
                Ok(Value::None)
            } else {
                Err(invalid("unexpected atom"))
            }
        }
        TermType::Integer => term
            .decode::<i64>()
            .map(Value::Int)
            .map_err(|_| invalid("integers must fit in 64 bits")),
        TermType::Float => term
            .decode::<f64>()
            .map(Value::Float)
            .map_err(|_| invalid("unexpected float")),
        TermType::Binary => {
            let string: &str = term
                .decode()
                .map_err(|_| invalid("strings must be valid UTF-8"))?;
            Ok(Value::Str(Str::from(string)))
        }
        TermType::List => {
            let items: Vec<Term> = term.decode().map_err(|_| invalid("improper list"))?;
            let array = items
                .into_iter()
                .map(|item| to_value(item, depth + 1))
                .collect::<Result<Array>>()?;
            Ok(Value::Array(array))
        }
        TermType::Map => {
            let mut dict = Dict::new();
            for (key, value) in MapIterator::new(term).ok_or_else(|| invalid("unexpected map"))? {
                let key: &str = key
                    .decode()
                    .map_err(|_| invalid("map keys must be strings"))?;
                dict.insert(Str::from(key), to_value(value, depth + 1)?);
            }
            Ok(Value::Dict(dict))
        }
        TermType::Tuple => tagged(term),
        _ => Err(invalid("unsupported term")),
    }
}

fn tagged(term: Term) -> Result<Value> {
    let elements =
        rustler::types::tuple::get_tuple(term).map_err(|_| invalid("unexpected tuple"))?;
    let (tag, fields) = elements
        .split_first()
        .ok_or_else(|| invalid("unexpected tuple"))?;

    let datetime = if atoms::date() == *tag {
        let [year, month, day] = integers(fields)?;
        Datetime::from_ymd(year, month as u8, day as u8)
    } else if atoms::time() == *tag {
        let [hour, minute, second] = integers(fields)?;
        Datetime::from_hms(hour as u8, minute as u8, second as u8)
    } else if atoms::datetime() == *tag {
        let [year, month, day, hour, minute, second] = integers(fields)?;
        Datetime::from_ymd_hms(
            year,
            month as u8,
            day as u8,
            hour as u8,
            minute as u8,
            second as u8,
        )
    } else if atoms::decimal() == *tag {
        let string: &str = match fields {
            [string] => string.decode().map_err(|_| invalid("unexpected decimal"))?,
            _ => return Err(invalid("unexpected decimal")),
        };

        return Decimal::from_str(string).map(Value::Decimal).map_err(|_| {
            invalid(&format!(
                "the decimal {string} doesn't fit in a Typst decimal, which has about 28 significant digits and at most 28 decimal places"
            ))
        });
    } else {
        return Err(invalid("unexpected tuple"));
    };

    datetime
        .map(Value::Datetime)
        .ok_or_else(|| invalid("the date or time is out of range for Typst"))
}

fn integers<const N: usize>(fields: &[Term]) -> Result<[i32; N]> {
    let fields: &[Term; N] = fields
        .try_into()
        .map_err(|_| invalid("unexpected date or time"))?;
    let mut integers = [0; N];

    for (integer, field) in integers.iter_mut().zip(fields) {
        *integer = field
            .decode()
            .map_err(|_| invalid("unexpected date or time"))?;
    }

    Ok(integers)
}

fn invalid(message: &str) -> String {
    format!("invalid variables: {message}")
}
