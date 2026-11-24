//! The rules for turning the data `Typsty.Value` builds into Typst values, shared by the NIF
//! (which reads terms) and the worker (which reads the external term format).
//!
//! The Elixir side has already turned atoms into strings, tuples into lists, map keys into
//! strings and structs into plain data, so only these terms arrive:
//!
//! - `nil`, `true` and `false`
//! - integers, floats and UTF-8 binaries
//! - lists and maps with binary keys
//! - `{:date, year, month, day}`, `{:time, hour, minute, second}`,
//!   `{:datetime, year, month, day, hour, minute, second}` and `{:decimal, string}`

use std::str::FromStr;

use typst::foundations::{Datetime, Decimal, Dict, Str, Value};

/// How deeply lists and maps may be nested. Typst recurses into values when it hashes,
/// compares and prints them, and the NIF converts them on a scheduler thread, which has a
/// small stack. `Typsty.Value` enforces the same limit with a better error message.
pub const MAX_DEPTH: usize = 256;

/// A dictionary of a map's entries, sorted by key. Erlang maps have no order of their own,
/// and the order the NIF and the worker see a map's entries in differs, so sorting gives
/// every dictionary the same, predictable order.
pub fn dict(mut entries: Vec<(Str, Value)>) -> Dict {
    entries.sort_by(|(a, _), (b, _)| a.as_str().cmp(b.as_str()));
    entries.into_iter().collect()
}

pub fn invalid(message: &str) -> String {
    format!("invalid variables: {message}")
}

/// The error for data nested deeper than `MAX_DEPTH`.
pub fn too_deep() -> String {
    invalid(&format!(
        "lists and maps can be nested at most {MAX_DEPTH} levels deep"
    ))
}

/// A `{:date, ...}`, `{:time, ...}` or `{:datetime, ...}` tuple, given its tag and fields.
pub fn datetime(tag: &str, fields: &[i64]) -> Result<Value, String> {
    let small = |value: i64| u8::try_from(value).ok();

    let datetime = match (tag, fields) {
        ("date", &[year, month, day]) => i32::try_from(year)
            .ok()
            .zip(small(month))
            .zip(small(day))
            .and_then(|((year, month), day)| Datetime::from_ymd(year, month, day)),
        ("time", &[hour, minute, second]) => small(hour)
            .zip(small(minute))
            .zip(small(second))
            .and_then(|((hour, minute), second)| Datetime::from_hms(hour, minute, second)),
        ("datetime", &[year, month, day, hour, minute, second]) => {
            match (
                i32::try_from(year).ok(),
                small(month),
                small(day),
                small(hour),
                small(minute),
                small(second),
            ) {
                (Some(year), Some(month), Some(day), Some(hour), Some(minute), Some(second)) => {
                    Datetime::from_ymd_hms(year, month, day, hour, minute, second)
                }
                _ => None,
            }
        }
        _ => return Err(invalid("unexpected date or time")),
    };

    datetime
        .map(Value::Datetime)
        .ok_or_else(|| invalid("the date or time is out of range for Typst"))
}

/// A `{:decimal, string}` tuple's string.
pub fn decimal(string: &str) -> Result<Value, String> {
    Decimal::from_str(string).map(Value::Decimal).map_err(|_| {
        invalid(&format!(
            "the decimal {string} doesn't fit in a Typst decimal, which has about 28 significant digits and at most 28 decimal places"
        ))
    })
}
