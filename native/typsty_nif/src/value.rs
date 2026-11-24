//! Converts the terms built by `Typsty.Value` into Typst values, following the rules in
//! `typsty_core::values`.

use rustler::{MapIterator, Term, TermType};
use typst::foundations::{Array, Dict, Str, Value};
use typsty_core::values::{self, invalid, MAX_DEPTH};

mod atoms {
    rustler::atoms! {
        nil,
    }
}

type Result<T> = std::result::Result<T, String>;

/// Converts the variables map into a dictionary of Typst values.
pub fn to_dict(term: Term) -> Result<Dict> {
    match to_value(term, 0)? {
        Value::Dict(dict) => Ok(dict),
        _ => Err(invalid("the variables must be a map")),
    }
}

fn to_value(term: Term, depth: usize) -> Result<Value> {
    if depth > MAX_DEPTH {
        return Err(values::too_deep());
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
            let entries = MapIterator::new(term)
                .ok_or_else(|| invalid("unexpected map"))?
                .map(|(key, value)| {
                    let key: &str = key
                        .decode()
                        .map_err(|_| invalid("map keys must be strings"))?;
                    Ok((Str::from(key), to_value(value, depth + 1)?))
                })
                .collect::<Result<Vec<_>>>()?;
            Ok(Value::Dict(values::dict(entries)))
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
    let tag = tag
        .atom_to_string()
        .map_err(|_| invalid("unexpected tuple"))?;

    if tag == "decimal" {
        return match fields {
            [string] => values::decimal(
                string
                    .decode::<&str>()
                    .map_err(|_| invalid("unexpected decimal"))?,
            ),
            _ => Err(invalid("unexpected decimal")),
        };
    }

    let fields = fields
        .iter()
        .map(|field| field.decode::<i64>())
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| invalid("unexpected date or time"))?;

    values::datetime(&tag, &fields)
}
