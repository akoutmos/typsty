//! Erlang's external term format, for the requests `Typsty.Pool` sends
//! (`:erlang.term_to_binary/1`) and the responses it reads (`:erlang.binary_to_term/2`).
//!
//! Only the terms Typsty uses are supported. Maps keep their order, so that Typst dicts are
//! built in the same order as the NIF builds them.

use std::fmt;

/// How deeply terms may be nested. Variables are nested at most 256 levels deep, and the
/// request wraps them in a few more.
const MAX_DEPTH: usize = 300;

const VERSION: u8 = 131;
const NEW_FLOAT_EXT: u8 = 70;
const SMALL_INTEGER_EXT: u8 = 97;
const INTEGER_EXT: u8 = 98;
const ATOM_EXT: u8 = 100;
const SMALL_TUPLE_EXT: u8 = 104;
const LARGE_TUPLE_EXT: u8 = 105;
const NIL_EXT: u8 = 106;
const STRING_EXT: u8 = 107;
const LIST_EXT: u8 = 108;
const BINARY_EXT: u8 = 109;
const SMALL_BIG_EXT: u8 = 110;
const LARGE_BIG_EXT: u8 = 111;
const SMALL_ATOM_EXT: u8 = 115;
const MAP_EXT: u8 = 116;
const ATOM_UTF8_EXT: u8 = 118;
const SMALL_ATOM_UTF8_EXT: u8 = 119;

#[derive(Debug, Clone, PartialEq)]
pub enum Term {
    Atom(String),
    Integer(i64),
    Float(f64),
    Binary(Vec<u8>),
    List(Vec<Term>),
    Tuple(Vec<Term>),
    Map(Vec<(Term, Term)>),
}

impl Term {
    pub fn atom(name: &str) -> Term {
        Term::Atom(name.to_string())
    }

    pub fn nil() -> Term {
        Term::atom("nil")
    }

    pub fn binary(bytes: impl Into<Vec<u8>>) -> Term {
        Term::Binary(bytes.into())
    }

    pub fn as_atom(&self) -> Option<&str> {
        match self {
            Term::Atom(name) => Some(name),
            _ => None,
        }
    }
}

#[derive(Debug)]
pub struct DecodeError(String);

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "invalid request: {}", self.0)
    }
}

fn error(message: impl Into<String>) -> DecodeError {
    DecodeError(message.into())
}

pub fn decode(bytes: &[u8]) -> Result<Term, DecodeError> {
    let mut reader = Reader { bytes, position: 0 };

    if reader.u8()? != VERSION {
        return Err(error("unknown version"));
    }

    let term = reader.term(0)?;
    if reader.position != bytes.len() {
        return Err(error("trailing bytes"));
    }

    Ok(term)
}

struct Reader<'a> {
    bytes: &'a [u8],
    position: usize,
}

impl Reader<'_> {
    fn take(&mut self, length: usize) -> Result<&[u8], DecodeError> {
        let end = self
            .position
            .checked_add(length)
            .filter(|&end| end <= self.bytes.len())
            .ok_or_else(|| error("unexpected end"))?;

        let slice = &self.bytes[self.position..end];
        self.position = end;
        Ok(slice)
    }

    fn u8(&mut self) -> Result<u8, DecodeError> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<usize, DecodeError> {
        Ok(u16::from_be_bytes(self.take(2)?.try_into().unwrap()) as usize)
    }

    fn u32(&mut self) -> Result<usize, DecodeError> {
        Ok(u32::from_be_bytes(self.take(4)?.try_into().unwrap()) as usize)
    }

    /// A count of elements that each take at least one byte, checked against what's left,
    /// so that a corrupt count can't ask for a huge allocation.
    fn count(&mut self, count: usize) -> Result<usize, DecodeError> {
        if count > self.bytes.len() - self.position {
            return Err(error("unexpected end"));
        }

        Ok(count)
    }

    fn term(&mut self, depth: usize) -> Result<Term, DecodeError> {
        if depth > MAX_DEPTH {
            return Err(error("terms are nested too deeply"));
        }

        let tag = self.u8()?;
        Ok(match tag {
            SMALL_INTEGER_EXT => Term::Integer(self.u8()? as i64),
            INTEGER_EXT => {
                Term::Integer(i32::from_be_bytes(self.take(4)?.try_into().unwrap()) as i64)
            }
            SMALL_BIG_EXT | LARGE_BIG_EXT => {
                let length = if tag == SMALL_BIG_EXT {
                    self.u8()? as usize
                } else {
                    self.u32()?
                };
                let negative = self.u8()? != 0;
                let digits = self.take(length)?;

                if digits.len() > 8 {
                    return Err(error("integers must fit in 64 bits"));
                }

                let magnitude = digits
                    .iter()
                    .rev()
                    .fold(0u64, |value, &digit| (value << 8) | digit as u64);
                let value = if negative {
                    0i64.checked_sub_unsigned(magnitude)
                } else {
                    i64::try_from(magnitude).ok()
                };

                Term::Integer(value.ok_or_else(|| error("integers must fit in 64 bits"))?)
            }
            NEW_FLOAT_EXT => Term::Float(f64::from_be_bytes(self.take(8)?.try_into().unwrap())),
            ATOM_UTF8_EXT | ATOM_EXT => {
                let length = self.u16()?;
                Term::Atom(self.atom_name(length, tag == ATOM_UTF8_EXT)?)
            }
            SMALL_ATOM_UTF8_EXT | SMALL_ATOM_EXT => {
                let length = self.u8()? as usize;
                Term::Atom(self.atom_name(length, tag == SMALL_ATOM_UTF8_EXT)?)
            }
            SMALL_TUPLE_EXT | LARGE_TUPLE_EXT => {
                let arity = if tag == SMALL_TUPLE_EXT {
                    self.u8()? as usize
                } else {
                    self.u32()?
                };
                let arity = self.count(arity)?;
                let elements = (0..arity)
                    .map(|_| self.term(depth + 1))
                    .collect::<Result<_, _>>()?;
                Term::Tuple(elements)
            }
            NIL_EXT => Term::List(Vec::new()),
            // A list of small integers, which Erlang encodes as bytes
            STRING_EXT => {
                let length = self.u16()?;
                Term::List(
                    self.take(length)?
                        .iter()
                        .map(|&byte| Term::Integer(byte as i64))
                        .collect(),
                )
            }
            LIST_EXT => {
                let length = self.u32()?;
                let length = self.count(length)?;
                let elements = (0..length)
                    .map(|_| self.term(depth + 1))
                    .collect::<Result<_, _>>()?;

                if self.u8()? != NIL_EXT {
                    return Err(error("improper lists aren't supported"));
                }

                Term::List(elements)
            }
            BINARY_EXT => {
                let length = self.u32()?;
                Term::Binary(self.take(length)?.to_vec())
            }
            MAP_EXT => {
                let arity = self.u32()?;
                let arity = self.count(arity)?;
                let entries = (0..arity)
                    .map(|_| Ok((self.term(depth + 1)?, self.term(depth + 1)?)))
                    .collect::<Result<_, DecodeError>>()?;
                Term::Map(entries)
            }
            other => return Err(error(format!("unsupported term (tag {other})"))),
        })
    }

    fn atom_name(&mut self, length: usize, utf8: bool) -> Result<String, DecodeError> {
        let bytes = self.take(length)?;

        if utf8 {
            String::from_utf8(bytes.to_vec()).map_err(|_| error("invalid atom"))
        } else {
            // Latin-1
            Ok(bytes.iter().map(|&byte| byte as char).collect())
        }
    }
}

pub fn encode(term: &Term) -> Vec<u8> {
    let mut bytes = vec![VERSION];
    write(term, &mut bytes);
    bytes
}

fn write(term: &Term, out: &mut Vec<u8>) {
    match term {
        Term::Atom(name) => {
            if name.len() < 256 {
                out.push(SMALL_ATOM_UTF8_EXT);
                out.push(name.len() as u8);
            } else {
                out.push(ATOM_UTF8_EXT);
                out.extend_from_slice(&(name.len() as u16).to_be_bytes());
            }
            out.extend_from_slice(name.as_bytes());
        }
        Term::Integer(value) => {
            if (0..=255).contains(value) {
                out.push(SMALL_INTEGER_EXT);
                out.push(*value as u8);
            } else if let Ok(value) = i32::try_from(*value) {
                out.push(INTEGER_EXT);
                out.extend_from_slice(&value.to_be_bytes());
            } else {
                out.push(SMALL_BIG_EXT);
                out.push(8);
                out.push(u8::from(*value < 0));
                out.extend_from_slice(&value.unsigned_abs().to_le_bytes());
            }
        }
        Term::Float(value) => {
            out.push(NEW_FLOAT_EXT);
            out.extend_from_slice(&value.to_be_bytes());
        }
        Term::Binary(bytes) => {
            out.push(BINARY_EXT);
            out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
            out.extend_from_slice(bytes);
        }
        Term::List(elements) if elements.is_empty() => out.push(NIL_EXT),
        Term::List(elements) => {
            out.push(LIST_EXT);
            out.extend_from_slice(&(elements.len() as u32).to_be_bytes());
            for element in elements {
                write(element, out);
            }
            out.push(NIL_EXT);
        }
        Term::Tuple(elements) => {
            if elements.len() < 256 {
                out.push(SMALL_TUPLE_EXT);
                out.push(elements.len() as u8);
            } else {
                out.push(LARGE_TUPLE_EXT);
                out.extend_from_slice(&(elements.len() as u32).to_be_bytes());
            }
            for element in elements {
                write(element, out);
            }
        }
        Term::Map(entries) => {
            out.push(MAP_EXT);
            out.extend_from_slice(&(entries.len() as u32).to_be_bytes());
            for (key, value) in entries {
                write(key, out);
                write(value, out);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips() {
        let term = Term::Tuple(vec![
            Term::atom("ok"),
            Term::Integer(-5_000_000_000),
            Term::Integer(i64::MIN),
            Term::Integer(70_000),
            Term::Float(1.5),
            Term::binary("héllo"),
            Term::List(vec![]),
            Term::Map(vec![
                (Term::atom("b"), Term::nil()),
                (Term::atom("a"), Term::Integer(1)),
            ]),
        ]);

        assert_eq!(decode(&encode(&term)).unwrap(), term);
    }

    #[test]
    fn decodes_strings_as_lists_of_integers() {
        // :erlang.term_to_binary([1, 2, 3])
        let bytes = [131, STRING_EXT, 0, 3, 1, 2, 3];
        let integers = (1..=3).map(Term::Integer).collect();
        assert_eq!(decode(&bytes).unwrap(), Term::List(integers));
    }

    #[test]
    fn rejects_corrupt_lengths() {
        assert!(decode(&[131, LIST_EXT, 255, 255, 255, 255]).is_err());
        assert!(decode(&[131, BINARY_EXT, 0, 0, 0, 9, 1]).is_err());
    }
}
