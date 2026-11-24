//! Checks on the files a document reads as data (images and data files), before Typst
//! decodes them.
//!
//! The libraries Typst decodes files with trust them: a small image can claim to be
//! enormous, a compressed SVG can expand to gigabytes, XML entities can expand a small file
//! a thousandfold, and deeply nested files can overflow the stack. A failed allocation aborts
//! the process, and so does a stack overflow, which inside the BEAM takes the whole VM down.
//! These checks refuse such files with an error instead.

use std::io::Read;
use std::sync::atomic::{AtomicBool, Ordering};

/// The most pixels an image may have: 2^27, about 134 megapixels, which takes 512 MiB
/// decoded.
pub const MAX_IMAGE_PIXELS: u64 = 1 << 27;

/// How deeply the elements of an XML (or SVG) file may be nested.
pub const MAX_XML_DEPTH: usize = 1024;

/// The most a compressed SVG may expand to: 128 MiB.
pub const MAX_DECOMPRESSED_SIZE: u64 = 128 * 1024 * 1024;

/// The most text an XML file's entities may expand to: 16 MiB.
pub const MAX_ENTITY_EXPANSION: usize = 16 * 1024 * 1024;

/// How far into a file Typst looks for the signs of a PDF or SVG.
const DETECTION_WINDOW: usize = 2048;

/// Whether PDF files may be read (see `allow_pdf_files`).
static PDF_FILES: AtomicBool = AtomicBool::new(false);

/// Lets documents read PDF files. Typst's PDF decoder recurses into nested PDF objects
/// without a limit, so a malformed PDF can overflow the stack, and it decodes the images in a
/// PDF without a limit on their size. That's only safe in a process of its own, so only the
/// worker (`Typsty.Pool`) allows them.
pub fn allow_pdf_files() {
    PDF_FILES.store(true, Ordering::Relaxed);
}

/// Checks a file's contents, given its file extension. Returns a description of the problem
/// for a file that's unsafe to give to Typst.
pub fn check(bytes: &[u8], extension: Option<&str>) -> Result<(), String> {
    // Typst decodes gzip as a compressed SVG
    if bytes.starts_with(&[0x1f, 0x8b]) {
        return check_xml(&decompress(bytes)?);
    }

    check_pdf(bytes, extension)?;
    check_image_size(bytes)?;
    check_xml(bytes)
}

fn check_pdf(bytes: &[u8], extension: Option<&str>) -> Result<(), String> {
    if PDF_FILES.load(Ordering::Relaxed) {
        return Ok(());
    }

    // Typst decodes a file as a PDF when its extension says so, or when it finds the PDF
    // header near its start
    let head = &bytes[..bytes.len().min(DETECTION_WINDOW)];
    let pdf = extension.is_some_and(|extension| extension.eq_ignore_ascii_case("pdf"))
        || find(head, b"%PDF-").is_some();

    if pdf {
        return Err("PDF files can't be used when rendering inside the VM: a malformed PDF can crash it. Render the document in a Typsty.Pool to use PDF files".into());
    }

    Ok(())
}

fn check_image_size(bytes: &[u8]) -> Result<(), String> {
    use imagesize::ImageType;

    // Only the formats Typst decodes are checked: imagesize recognizes many more, and could
    // mistake a data file for one of them
    match imagesize::image_type(bytes) {
        Ok(ImageType::Png | ImageType::Jpeg | ImageType::Gif | ImageType::Webp) => {}
        _ => return Ok(()),
    }

    let Ok(size) = imagesize::blob_size(bytes) else {
        return Ok(());
    };

    let pixels = (size.width as u64).saturating_mul(size.height as u64);
    if pixels > MAX_IMAGE_PIXELS {
        return Err(format!(
            "the image is too large to decode: {} × {} pixels (at most {MAX_IMAGE_PIXELS} pixels)",
            size.width, size.height
        ));
    }

    Ok(())
}

/// Decompresses a gzip file, up to `MAX_DECOMPRESSED_SIZE`. Like usvg, only the first gzip
/// member is read.
fn decompress(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut decompressed = Vec::new();
    let read = flate2::read::GzDecoder::new(bytes)
        .take(MAX_DECOMPRESSED_SIZE + 1)
        .read_to_end(&mut decompressed);

    match read {
        Ok(_) if decompressed.len() as u64 > MAX_DECOMPRESSED_SIZE => Err(format!(
            "the compressed file expands to more than {} MiB",
            MAX_DECOMPRESSED_SIZE / 1024 / 1024
        )),
        // An invalid file is left for Typst to report
        Ok(_) | Err(_) => Ok(decompressed),
    }
}

/// Checks content that looks like XML (or SVG): how deeply its elements are nested, and what
/// its entities expand to.
///
/// This is a rough scan, not a parser. Typst's XML parser (roxmltree) refuses files that
/// aren't well-formed, so only well-formed files can nest deeply once parsed. The scan only
/// refuses those, which leaves files such as HTML (with its unclosed `<br>` and `<img>`)
/// alone.
fn check_xml(bytes: &[u8]) -> Result<(), String> {
    let content = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(bytes);
    let start = content
        .iter()
        .position(|byte| !byte.is_ascii_whitespace())
        .unwrap_or(content.len());

    if content.get(start) != Some(&b'<') {
        return Ok(());
    }

    let mut entities: Vec<(&[u8], usize)> = Vec::new();
    // The open elements' names
    let mut open: Vec<&[u8]> = Vec::new();
    let mut deepest = 0;
    let mut index = start;

    while let Some(offset) = find(&content[index..], b"<") {
        index += offset;
        let rest = &content[index..];

        if rest.starts_with(b"<!--") {
            index += skip_past(rest, b"-->");
        } else if rest.starts_with(b"<![CDATA[") {
            index += skip_past(rest, b"]]>");
        } else if rest.starts_with(b"<?") {
            index += skip_past(rest, b"?>");
        } else if rest.starts_with(b"<!DOCTYPE") {
            index += doctype(rest, &mut entities)?;
        } else if rest.starts_with(b"<!") {
            index += tag_end(rest);
        } else if rest.starts_with(b"</") {
            let name = tag_name(&rest[2..]);
            if open.pop() != Some(name) {
                // Not well-formed, so the parser refuses it
                return Ok(());
            }
            index += skip_past(rest, b">");
        } else {
            let end = tag_end(rest);
            if !rest[..end].ends_with(b"/>") {
                open.push(tag_name(&rest[1..]));
                deepest = deepest.max(open.len());
            }
            index += end;
        }
    }

    if !open.is_empty() {
        // Elements left open: not well-formed
        return Ok(());
    }

    if deepest > MAX_XML_DEPTH {
        return Err(format!(
            "the file's elements are nested more than {MAX_XML_DEPTH} levels deep"
        ));
    }

    check_entity_expansion(content, &entities)
}

/// Reads a DOCTYPE declaration, collecting the entities its internal subset declares.
/// Returns its length.
fn doctype<'a>(bytes: &'a [u8], entities: &mut Vec<(&'a [u8], usize)>) -> Result<usize, String> {
    // Up to the internal subset's `[`, or the end of a declaration without one
    let mut index = "<!DOCTYPE".len();
    loop {
        match bytes.get(index) {
            None => return Ok(bytes.len()),
            Some(b'>') => return Ok(index + 1),
            Some(b'[') => break,
            Some(&quote @ (b'"' | b'\'')) => index += 1 + skip_past(&bytes[index + 1..], &[quote]),
            Some(_) => index += 1,
        }
    }

    index += 1;
    loop {
        let rest = &bytes[index..];
        let Some(byte) = rest.first() else {
            return Ok(bytes.len());
        };

        if byte.is_ascii_whitespace() {
            index += 1;
        } else if *byte == b']' {
            // The subset ends with `]`, then optional spaces, then `>`
            return Ok(index + skip_past(rest, b">"));
        } else if rest.starts_with(b"<!--") {
            index += skip_past(rest, b"-->");
        } else if rest.starts_with(b"<?") {
            index += skip_past(rest, b"?>");
        } else if rest.starts_with(b"<!ENTITY") {
            index += entity(rest, entities)?;
        } else if rest.starts_with(b"<!") {
            index += tag_end(rest);
        } else {
            // A parameter entity reference, or something the parser will refuse
            index += 1;
        }
    }
}

/// Reads an entity declaration, recording its name and the length of its value. Returns its
/// length.
fn entity<'a>(bytes: &'a [u8], entities: &mut Vec<(&'a [u8], usize)>) -> Result<usize, String> {
    let mut index = "<!ENTITY".len();
    let skip_spaces = |index: &mut usize| {
        while bytes.get(*index).is_some_and(u8::is_ascii_whitespace) {
            *index += 1;
        }
    };

    skip_spaces(&mut index);
    if bytes.get(index) == Some(&b'%') {
        index += 1;
        skip_spaces(&mut index);
    }

    let name = tag_name(&bytes[index..]);
    index += name.len();
    skip_spaces(&mut index);

    if let Some(&quote @ (b'"' | b'\'')) = bytes.get(index) {
        let value_length = find(&bytes[index + 1..], &[quote]).unwrap_or(bytes.len() - index - 1);
        let value = &bytes[index + 1..index + 1 + value_length];

        // An entity that refers to other entities can expand exponentially, and one with
        // markup can nest elements without limit
        if value.iter().any(|byte| matches!(byte, b'&' | b'%' | b'<')) {
            return Err(
                "the file declares an XML entity that contains markup or refers to other entities, which isn't supported".into(),
            );
        }

        entities.push((name, value.len()));
        index += value_length + 2;
    }

    Ok(index + skip_past(&bytes[index.min(bytes.len())..], b">"))
}

/// Adds up what the references to the declared entities expand to.
fn check_entity_expansion(content: &[u8], entities: &[(&[u8], usize)]) -> Result<(), String> {
    if entities.is_empty() {
        return Ok(());
    }

    let mut expansion: usize = 0;
    let mut index = 0;

    while let Some(offset) = find(&content[index..], b"&") {
        index += offset + 1;
        let rest = &content[index..];

        if let Some(end) = rest.iter().take(256).position(|&byte| byte == b';') {
            let name = &rest[..end];
            if let Some((_, length)) = entities.iter().find(|(entity, _)| *entity == name) {
                expansion = expansion.saturating_add(*length);

                if expansion > MAX_ENTITY_EXPANSION {
                    return Err(format!(
                        "the file's XML entities expand to more than {} MiB",
                        MAX_ENTITY_EXPANSION / 1024 / 1024
                    ));
                }
            }
        }
    }

    Ok(())
}

/// The name at the start of a tag or declaration.
fn tag_name(bytes: &[u8]) -> &[u8] {
    let end = bytes
        .iter()
        .position(|&byte| byte.is_ascii_whitespace() || matches!(byte, b'/' | b'>'))
        .unwrap_or(bytes.len());
    &bytes[..end]
}

/// The position of the first occurrence of `pattern`.
fn find(bytes: &[u8], pattern: &[u8]) -> Option<usize> {
    bytes
        .windows(pattern.len())
        .position(|window| window == pattern)
}

/// The length up to and including the first occurrence of `pattern`, or the whole slice.
fn skip_past(bytes: &[u8], pattern: &[u8]) -> usize {
    find(bytes, pattern).map_or(bytes.len(), |position| position + pattern.len())
}

/// The length of a tag, up to and including its `>`, skipping quoted attribute values.
fn tag_end(bytes: &[u8]) -> usize {
    let mut quote = None;

    for (index, &byte) in bytes.iter().enumerate().skip(1) {
        match quote {
            Some(open) if byte == open => quote = None,
            Some(_) => {}
            None if byte == b'"' || byte == b'\'' => quote = Some(byte),
            None if byte == b'>' => return index + 1,
            None => {}
        }
    }

    bytes.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nested(depth: usize) -> String {
        format!("{}{}", "<a>".repeat(depth), "</a>".repeat(depth))
    }

    #[test]
    fn refuses_deeply_nested_xml() {
        assert!(check_xml(b"<a><b/><c x='>'><!-- <d> --></c></a>").is_ok());
        assert!(check_xml(b"not xml <<<<").is_ok());
        assert!(check_xml(nested(MAX_XML_DEPTH).as_bytes()).is_ok());
        assert!(check_xml(nested(MAX_XML_DEPTH + 1).as_bytes()).is_err());

        let siblings = "<a></a>".repeat(MAX_XML_DEPTH * 10);
        assert!(check_xml(format!("<r>{siblings}</r>").as_bytes()).is_ok());
    }

    #[test]
    fn leaves_files_that_arent_well_formed_to_the_parser() {
        // HTML, with unclosed elements
        let html = format!("<html><body>{}</body></html>", "line<br>".repeat(2000));
        assert!(check_xml(html.as_bytes()).is_ok());

        // A Typst file that starts with a label
        let typst = format!("<intro>\n{}", "= Heading <label>\n".repeat(2000));
        assert!(check_xml(typst.as_bytes()).is_ok());
    }

    #[test]
    fn reads_past_doctypes() {
        let deep = nested(MAX_XML_DEPTH + 1);
        assert!(check_xml(format!("<!DOCTYPE a [] >{deep}").as_bytes()).is_err());
        assert!(check_xml(format!("<!DOCTYPE a [ <!-- ]> --> ]>{deep}").as_bytes()).is_err());
        assert!(check_xml(
            format!("<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"x>\">{deep}").as_bytes()
        )
        .is_err());
    }

    #[test]
    fn limits_entities() {
        // Like Adobe Illustrator's SVGs
        let svg = r#"<!DOCTYPE svg [ <!ENTITY ns_svg "http://www.w3.org/2000/svg"> ]><svg xmlns="&ns_svg;"/>"#;
        assert!(check_xml(svg.as_bytes()).is_ok());

        let nested = r#"<!DOCTYPE a [ <!ENTITY a "aaaa"> <!ENTITY b "&a;&a;"> ]><a>&b;</a>"#;
        assert!(check_xml(nested.as_bytes()).is_err());

        let markup = r#"<!DOCTYPE a [ <!ENTITY a "<b><b>"> ]><a>&a;</a>"#;
        assert!(check_xml(markup.as_bytes()).is_err());

        let value = "x".repeat(64 * 1024);
        let references = "&big;".repeat(300);
        let quadratic = format!("<!DOCTYPE a [ <!ENTITY big \"{value}\"> ]><a>{references}</a>");
        assert!(check_xml(quadratic.as_bytes()).is_err());
    }

    #[test]
    fn refuses_compressed_files_that_expand_too_much() {
        use std::io::Write;

        let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::best());
        let chunk = vec![b' '; 1024 * 1024];
        for _ in 0..=(MAX_DECOMPRESSED_SIZE / chunk.len() as u64) {
            encoder.write_all(&chunk).unwrap();
        }
        let bomb = encoder.finish().unwrap();

        assert!(check(&bomb, Some("svg"))
            .unwrap_err()
            .contains("expands to more than"));
    }

    #[test]
    fn refuses_pdf_files() {
        assert!(check(b"%PDF-1.7\n...", None).is_err());
        assert!(check(b"junk", Some("PDF")).is_err());
        assert!(check(b"name,price\nBMW,1", Some("csv")).is_ok());
    }
}
