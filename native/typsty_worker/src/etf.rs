//! Erlang's external term format, for the requests `Typsty.Pool` sends
//! (`:erlang.term_to_binary/1`) and the responses it reads (`:erlang.binary_to_term/2`).
//!
//! Only the terms Typsty uses are supported. Maps keep the order of their entries; Typst
//! dictionaries are sorted by key either way (see `typsty_core::values::dict`).

use std::fmt;
use std::io::{self, Write};

/// How deeply terms may be nested. Assigns are nested at most 256 levels deep, and the
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

/// Writes the term in the external term format, prefixed with its length as 4 bytes
/// (`{:packet, 4}`). Binaries are written as they are, without copying them into a buffer.
pub fn write_frame(term: &Term, out: &mut impl Write) -> io::Result<()> {
    let length = 1 + encoded_length(term);
    let length = u32::try_from(length)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "response too large"))?;

    out.write_all(&length.to_be_bytes())?;
    out.write_all(&[VERSION])?;
    write(term, out)
}

#[cfg(test)]
pub fn encode(term: &Term) -> Vec<u8> {
    let mut bytes = Vec::new();
    write_frame(term, &mut bytes).unwrap();
    bytes.split_off(4)
}

fn encoded_length(term: &Term) -> usize {
    match term {
        Term::Atom(name) if name.len() < 256 => 2 + name.len(),
        Term::Atom(name) => 3 + name.len(),
        Term::Integer(value) if (0..=255).contains(value) => 2,
        Term::Integer(value) if i32::try_from(*value).is_ok() => 5,
        Term::Integer(_) => 11,
        Term::Float(_) => 9,
        Term::Binary(bytes) => 5 + bytes.len(),
        Term::List(elements) if elements.is_empty() => 1,
        Term::List(elements) => 6 + elements.iter().map(encoded_length).sum::<usize>(),
        Term::Tuple(elements) => {
            let header = if elements.len() < 256 { 2 } else { 5 };
            header + elements.iter().map(encoded_length).sum::<usize>()
        }
        Term::Map(entries) => {
            5 + entries
                .iter()
                .map(|(key, value)| encoded_length(key) + encoded_length(value))
                .sum::<usize>()
        }
    }
}

fn write(term: &Term, out: &mut impl Write) -> io::Result<()> {
    match term {
        Term::Atom(name) => {
            if name.len() < 256 {
                out.write_all(&[SMALL_ATOM_UTF8_EXT, name.len() as u8])?;
            } else {
                out.write_all(&[ATOM_UTF8_EXT])?;
                out.write_all(&(name.len() as u16).to_be_bytes())?;
            }
            out.write_all(name.as_bytes())
        }
        Term::Integer(value) => {
            if (0..=255).contains(value) {
                out.write_all(&[SMALL_INTEGER_EXT, *value as u8])
            } else if let Ok(value) = i32::try_from(*value) {
                out.write_all(&[INTEGER_EXT])?;
                out.write_all(&value.to_be_bytes())
            } else {
                out.write_all(&[SMALL_BIG_EXT, 8, u8::from(*value < 0)])?;
                out.write_all(&value.unsigned_abs().to_le_bytes())
            }
        }
        Term::Float(value) => {
            out.write_all(&[NEW_FLOAT_EXT])?;
            out.write_all(&value.to_be_bytes())
        }
        Term::Binary(bytes) => {
            out.write_all(&[BINARY_EXT])?;
            out.write_all(&(bytes.len() as u32).to_be_bytes())?;
            out.write_all(bytes)
        }
        Term::List(elements) if elements.is_empty() => out.write_all(&[NIL_EXT]),
        Term::List(elements) => {
            out.write_all(&[LIST_EXT])?;
            out.write_all(&(elements.len() as u32).to_be_bytes())?;
            for element in elements {
                write(element, out)?;
            }
            out.write_all(&[NIL_EXT])
        }
        Term::Tuple(elements) => {
            if elements.len() < 256 {
                out.write_all(&[SMALL_TUPLE_EXT, elements.len() as u8])?;
            } else {
                out.write_all(&[LARGE_TUPLE_EXT])?;
                out.write_all(&(elements.len() as u32).to_be_bytes())?;
            }
            for element in elements {
                write(element, out)?;
            }
            Ok(())
        }
        Term::Map(entries) => {
            out.write_all(&[MAP_EXT])?;
            out.write_all(&(entries.len() as u32).to_be_bytes())?;
            for (key, value) in entries {
                write(key, out)?;
                write(value, out)?;
            }
            Ok(())
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

        let encoded = encode(&term);
        assert_eq!(encoded.len(), 1 + encoded_length(&term));
        assert_eq!(decode(&encoded).unwrap(), term);
    }

    #[test]
    fn decodes_what_erlang_encodes() {
        // :erlang.term_to_binary({9223372036854775807, -9223372036854775808, :héllo, :"é"})
        // with the last atom encoded as Latin-1 (ATOM_EXT), as older nodes do
        let bytes = [
            131, 104, 4, 110, 8, 0, 255, 255, 255, 255, 255, 255, 255, 127, 110, 8, 1, 0, 0, 0, 0,
            0, 0, 0, 128, 119, 6, 104, 195, 169, 108, 108, 111, 100, 0, 1, 233,
        ];

        assert_eq!(
            decode(&bytes).unwrap(),
            Term::Tuple(vec![
                Term::Integer(i64::MAX),
                Term::Integer(i64::MIN),
                Term::atom("héllo"),
                Term::atom("é"),
            ])
        );

        // 2^64 doesn't fit
        assert!(decode(&[131, 110, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]).is_err());
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
