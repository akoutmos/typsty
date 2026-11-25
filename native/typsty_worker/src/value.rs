//! Converts the assigns in a request into Typst values, following the same rules as the
//! NIF (see `typsty_core::values`).

use typst::foundations::{Array, Dict, Str, Value};
use typsty_core::values::{self, invalid, MAX_DEPTH};

use crate::etf::Term;

type Result<T> = std::result::Result<T, String>;

/// Converts the assigns map into a dictionary of Typst values.
pub fn to_dict(term: &Term) -> Result<Dict> {
    match to_value(term, 0)? {
        Value::Dict(dict) => Ok(dict),
        _ => Err(invalid("the assigns must be a map")),
    }
}

fn to_value(term: &Term, depth: usize) -> Result<Value> {
    if depth > MAX_DEPTH {
        return Err(values::too_deep());
    }

    match term {
        Term::Atom(name) => match name.as_str() {
            "nil" => Ok(Value::None),
            "true" => Ok(Value::Bool(true)),
            "false" => Ok(Value::Bool(false)),
            _ => Err(invalid("unexpected atom")),
        },
        Term::Integer(integer) => Ok(Value::Int(*integer)),
        Term::Float(float) => Ok(Value::Float(*float)),
        Term::Binary(bytes) => std::str::from_utf8(bytes)
            .map(|string| Value::Str(Str::from(string)))
            .map_err(|_| invalid("strings must be valid UTF-8")),
        Term::List(items) => items
            .iter()
            .map(|item| to_value(item, depth + 1))
            .collect::<Result<Array>>()
            .map(Value::Array),
        Term::Map(entries) => {
            let entries = entries
                .iter()
                .map(|(key, value)| {
                    let Term::Binary(key) = key else {
                        return Err(invalid("map keys must be strings"));
                    };
                    let key = std::str::from_utf8(key)
                        .map_err(|_| invalid("map keys must be strings"))?;
                    Ok((Str::from(key), to_value(value, depth + 1)?))
                })
                .collect::<Result<Vec<_>>>()?;
            Ok(Value::Dict(values::dict(entries)))
        }
        Term::Tuple(elements) => tagged(elements),
    }
}

fn tagged(elements: &[Term]) -> Result<Value> {
    let Some((Term::Atom(tag), fields)) = elements.split_first() else {
        return Err(invalid("unexpected tuple"));
    };

    if tag == "decimal" {
        return match fields {
            [Term::Binary(string)] => values::decimal(
                std::str::from_utf8(string).map_err(|_| invalid("unexpected decimal"))?,
            ),
            _ => Err(invalid("unexpected decimal")),
        };
    }

    let fields = fields
        .iter()
        .map(|field| match field {
            Term::Integer(integer) => Ok(*integer),
            _ => Err(invalid("unexpected date or time")),
        })
        .collect::<Result<Vec<_>>>()?;

    values::datetime(tag, &fields)
}
