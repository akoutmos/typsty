//! Checks on the files a document reads as data (images and data files), before Typst
//! decodes them.
//!
//! The libraries Typst decodes files with trust them: a small image can claim to be
//! enormous, a compressed SVG can expand to gigabytes, XML entities can expand a small file
//! a thousandfold, a CBOR file can declare billions of items, and deeply nested files can
//! overflow the stack or take quadratic time. A failed allocation aborts the process, and so
//! does a stack overflow, which inside the BEAM takes the whole VM down. These checks refuse
//! the files known to do that with an error instead.
//!
//! They can't cover everything the decoders might do with a hostile file, which is why
//! files from untrusted sources are best rendered in a separate process (`Typsty.Pool`).
//! There, some formats that are too risky inside the VM are allowed (see `isolate`).

use std::collections::HashMap;
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

/// How deeply braces may be nested in a BibTeX file, and brackets in a YAML file's flow
/// collections: parsing deeply nested ones takes quadratic time, which can't be cancelled.
pub const MAX_BRACKET_DEPTH: usize = 256;

/// How far into a file Typst looks for the signs of a PDF.
const DETECTION_WINDOW: usize = 2048;

/// Whether the process can crash without harm (see `isolate`).
static ISOLATED: AtomicBool = AtomicBool::new(false);

/// Allows the formats that are only safe in a process of its own, which is what the worker
/// (`Typsty.Pool`) is:
///
/// - PDF files: Typst's PDF decoder (hayro) decodes the images in a PDF without a limit on
///   their size.
/// - SVG images that contain other SVG images (as `data:` URLs): those are parsed, and
///   decompressed, without the limits these checks apply to files, and can nest to make
///   the work exponential.
///
/// In the worker, the memory limit and the timeout stop what these do.
pub fn isolate() {
    ISOLATED.store(true, Ordering::Relaxed);
}

fn isolated() -> bool {
    ISOLATED.load(Ordering::Relaxed)
}

/// Checks a file's contents, given its file extension. Returns a description of the problem
/// for a file that's unsafe to give to Typst.
pub fn check(bytes: &[u8], extension: Option<&str>) -> Result<(), String> {
    // Before anything else: Typst decodes a file as a PDF by its extension, whatever its
    // contents look like
    check_pdf(bytes, extension)?;

    // Typst decodes gzip as a compressed SVG
    if bytes.starts_with(&[0x1f, 0x8b]) {
        return check_xml(&decompress(bytes)?);
    }

    check_image_size(bytes)?;
    check_cbor(bytes, extension)?;
    check_brackets(bytes, extension)?;
    check_xml(bytes)
}

fn has_extension(extension: Option<&str>, names: &[&str]) -> bool {
    extension.is_some_and(|extension| {
        names
            .iter()
            .any(|name| extension.eq_ignore_ascii_case(name))
    })
}

fn check_pdf(bytes: &[u8], extension: Option<&str>) -> Result<(), String> {
    if isolated() {
        return Ok(());
    }

    // Typst decodes a file as a PDF when its extension says so, when it finds the PDF header
    // near its start, or when a template asks for one with `format: "pdf"`. Its decoder
    // doesn't need the header, but every PDF it can decode has objects, which end with
    // `endobj`
    let head = &bytes[..bytes.len().min(DETECTION_WINDOW)];
    let pdf = has_extension(extension, &["pdf"])
        || memchr::memmem::find(head, b"%PDF-").is_some()
        || memchr::memmem::find(bytes, b"endobj").is_some();

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

/// CBOR arrays and maps declare how many items they have, and Typst's decoder reserves
/// memory for that many items before reading them: a few bytes can declare trillions.
/// Every array and map must declare fewer items than there are bytes left, since each item
/// takes at least one.
///
/// Typst reads CBOR from any file a template passes to `cbor`, so files that start like a
/// CBOR array or map are checked too, unless they're images.
fn check_cbor(bytes: &[u8], extension: Option<&str>) -> Result<(), String> {
    let looks_like_cbor =
        matches!(bytes.first(), Some(0x80..=0xBF)) && imagesize::image_type(bytes).is_err();
    if !(has_extension(extension, &["cbor"]) || looks_like_cbor) {
        return Ok(());
    }

    // The items still to read in each open array or map (u64::MAX for indefinite lengths)
    let mut open: Vec<u64> = vec![1];
    let mut position = 0;

    while let Some(&byte) = bytes.get(position) {
        if open.is_empty() {
            break;
        }

        position += 1;

        // The break that ends an indefinite-length item
        if byte == 0xff {
            open.pop();
            finish_item(&mut open);
            continue;
        }

        let (major, info) = (byte >> 5, byte & 0x1f);
        let argument = match info {
            0..=23 => Some(info as u64),
            24..=27 => {
                let size = 1 << (info - 24);
                let Some(field) = bytes.get(position..position + size) else {
                    return Ok(());
                };
                position += size;
                Some(
                    field
                        .iter()
                        .fold(0u64, |value, &byte| (value << 8) | byte as u64),
                )
            }
            31 => None,
            // Not CBOR, which Typst will report
            _ => return Ok(()),
        };

        let left = (bytes.len() - position) as u64;

        match (major, argument) {
            // Byte and text strings
            (2 | 3, Some(length)) => {
                if length > left {
                    return Ok(());
                }
                position += length as usize;
            }
            // Arrays and maps
            (4 | 5, Some(count)) => {
                let items = if major == 5 {
                    count.saturating_mul(2)
                } else {
                    count
                };

                if items > left {
                    return Err(format!(
                        "the CBOR data declares {count} {} items, more than its {left} remaining bytes could hold",
                        if major == 5 { "map" } else { "array" },
                    ));
                }

                if items > 0 {
                    open.push(items);
                    continue;
                }
            }
            // Indefinite-length strings, arrays and maps, which end with a break
            (2..=5, None) => {
                open.push(u64::MAX);
                continue;
            }
            // A tag applies to the next item, which is counted instead
            (6, _) => continue,
            _ => {}
        }

        finish_item(&mut open);
    }

    Ok(())
}

/// Counts an item as read in the innermost open array or map, closing those it completes.
fn finish_item(open: &mut Vec<u64>) {
    while let Some(remaining) = open.last_mut() {
        if *remaining == u64::MAX {
            return;
        }

        *remaining -= 1;
        if *remaining > 0 {
            return;
        }

        open.pop();
    }
}

/// Typst's BibTeX parser takes quadratic time on deeply nested braces, and the work can't be
/// cancelled; YAML flow collections nest the same way.
fn check_brackets(bytes: &[u8], extension: Option<&str>) -> Result<(), String> {
    let pairs: &[(u8, u8)] = if has_extension(extension, &["bib"]) {
        &[(b'{', b'}')]
    } else if has_extension(extension, &["yml", "yaml"]) {
        &[(b'[', b']'), (b'{', b'}')]
    } else {
        return Ok(());
    };

    let mut depth: usize = 0;
    for &byte in bytes {
        if pairs.iter().any(|&(open, _)| byte == open) {
            depth += 1;
            if depth > MAX_BRACKET_DEPTH {
                return Err(format!(
                    "the file's brackets are nested more than {MAX_BRACKET_DEPTH} levels deep"
                ));
            }
        } else if pairs.iter().any(|&(_, close)| byte == close) {
            depth = depth.saturating_sub(1);
        }
    }

    Ok(())
}

/// Checks content that looks like XML (or SVG): what its entities expand to, how deeply its
/// elements are nested, and the images an SVG embeds as `data:` URLs.
///
/// The depth is measured on the document as Typst's XML parser (roxmltree, which doesn't
/// recurse) reads it, so it's exact. A file the parser refuses can't be decoded at all, so
/// it's left for Typst to report.
fn check_xml(bytes: &[u8]) -> Result<(), String> {
    let content = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(bytes);
    let start = content
        .iter()
        .position(|byte| !byte.is_ascii_whitespace())
        .unwrap_or(content.len());

    if content.get(start) != Some(&b'<') {
        return Ok(());
    }

    // Before parsing, since parsing expands the entities
    check_entities(content)?;

    let Ok(text) = std::str::from_utf8(content) else {
        return Ok(());
    };

    let options = roxmltree::ParsingOptions {
        allow_dtd: true,
        ..roxmltree::ParsingOptions::default()
    };

    let Ok(document) = roxmltree::Document::parse_with_options(text, options) else {
        return Ok(());
    };

    check_depth(&document)?;
    check_data_urls(&document)
}

fn check_depth(document: &roxmltree::Document) -> Result<(), String> {
    // Nodes come in document order, so a node's parent comes before it
    let mut depths: Vec<usize> = Vec::new();

    for node in document.root().descendants() {
        let depth = node
            .parent()
            .and_then(|parent| depths.get(parent.id().get_usize()))
            .map_or(0, |depth| depth + 1);

        if depth > MAX_XML_DEPTH {
            return Err(format!(
                "the file's elements are nested more than {MAX_XML_DEPTH} levels deep"
            ));
        }

        let id = node.id().get_usize();
        if depths.len() <= id {
            depths.resize(id + 1, 0);
        }
        depths[id] = depth;
    }

    Ok(())
}

/// The images an SVG embeds as `data:` URLs, which Typst's SVG library decodes without the
/// checks the files a document reads get. Raster images are checked like files. SVG images,
/// which the library parses (and decompresses) without limits, are refused inside the VM.
fn check_data_urls(document: &roxmltree::Document) -> Result<(), String> {
    for node in document
        .root()
        .descendants()
        .filter(|node| node.is_element())
    {
        for attribute in node.attributes() {
            let value = attribute.value().trim_start();
            if !value
                .get(..5)
                .is_some_and(|scheme| scheme.eq_ignore_ascii_case("data:"))
            {
                continue;
            }

            let Ok(url) = data_url::DataUrl::process(value) else {
                continue;
            };
            let Ok((payload, _fragment)) = url.decode_to_vec() else {
                continue;
            };

            let mime = url.mime_type();
            let raster = imagesize::image_type(&payload).is_ok();

            match (mime.type_.as_str(), mime.subtype.as_str()) {
                ("image", "jpg" | "jpeg" | "png" | "gif" | "webp") => check_image_size(&payload)?,
                ("text", "plain") if raster => check_image_size(&payload)?,
                ("image", "svg+xml") | ("text", "plain") if !isolated() => {
                    return Err("SVG images that contain other SVG images can't be used when rendering inside the VM. Render the document in a Typsty.Pool to use them".into());
                }
                // The SVG library ignores other types
                _ => {}
            }
        }
    }

    Ok(())
}

/// Entities refer to text declared in the document's DTD, which the parser expands. An
/// entity that refers to other entities can expand exponentially, and one with markup can
/// nest elements without limit, so those are refused. The others expand to their value at
/// every reference, which is added up.
///
/// The declarations are found anywhere in the file, rather than by parsing the DTD, so that
/// nothing can hide one from the scan; one in a comment is only counted too.
fn check_entities(content: &[u8]) -> Result<(), String> {
    let mut entities: HashMap<&[u8], usize> = HashMap::new();

    for start in memchr::memmem::find_iter(content, b"<!ENTITY") {
        let mut rest = skip_spaces(&content[start + "<!ENTITY".len()..]);
        if let Some(after) = rest.strip_prefix(b"%") {
            rest = skip_spaces(after);
        }

        let name_length = rest
            .iter()
            .position(|byte| byte.is_ascii_whitespace())
            .unwrap_or(rest.len());
        let name = &rest[..name_length];
        rest = skip_spaces(&rest[name_length..]);

        if let Some(&quote @ (b'"' | b'\'')) = rest.first() {
            let value = &rest[1..];
            let value = &value[..memchr::memchr(quote, value).unwrap_or(value.len())];

            if value.iter().any(|byte| matches!(byte, b'&' | b'%' | b'<')) {
                return Err(
                    "the file declares an XML entity that contains markup or refers to other entities, which isn't supported".into(),
                );
            }

            entities.insert(name, value.len());
        }
    }

    if entities.is_empty() {
        return Ok(());
    }

    let mut expansion: usize = 0;

    for start in memchr::memchr_iter(b'&', content) {
        let rest = &content[start + 1..];
        let Some(end) = memchr::memchr(b';', rest) else {
            break;
        };

        if let Some(length) = entities.get(&rest[..end]) {
            expansion = expansion.saturating_add(*length);

            if expansion > MAX_ENTITY_EXPANSION {
                return Err(format!(
                    "the file's XML entities expand to more than {} MiB",
                    MAX_ENTITY_EXPANSION / 1024 / 1024
                ));
            }
        }
    }

    Ok(())
}

fn skip_spaces(bytes: &[u8]) -> &[u8] {
    let start = bytes
        .iter()
        .position(|byte| !byte.is_ascii_whitespace())
        .unwrap_or(bytes.len());
    &bytes[start..]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nested(depth: usize) -> String {
        format!("{}{}", "<a>".repeat(depth), "</a>".repeat(depth))
    }

    fn base64(bytes: &[u8]) -> String {
        const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for chunk in bytes.chunks(3) {
            let value = chunk
                .iter()
                .fold(0u32, |value, &byte| (value << 8) | byte as u32)
                << (8 * (3 - chunk.len()));
            for index in 0..4 {
                if index <= chunk.len() {
                    out.push(ALPHABET[((value >> (18 - 6 * index)) & 63) as usize] as char);
                } else {
                    out.push('=');
                }
            }
        }
        out
    }

    #[test]
    fn refuses_deeply_nested_xml() {
        assert!(check_xml(b"<a><b/><c x='>'><!-- <d> --></c></a>").is_ok());
        assert!(check_xml(b"not xml <<<<").is_ok());
        assert!(check_xml(nested(MAX_XML_DEPTH).as_bytes()).is_ok());
        assert!(check_xml(nested(MAX_XML_DEPTH + 1).as_bytes()).is_err());

        let siblings = "<a></a>".repeat(MAX_XML_DEPTH * 10);
        assert!(check_xml(format!("<r>{siblings}</r>").as_bytes()).is_ok());

        // Comments can't hide elements from the check
        let tricky = format!("<!--></x>-->{}", nested(MAX_XML_DEPTH + 1));
        assert!(check_xml(tricky.as_bytes()).is_err());
    }

    #[test]
    fn leaves_files_that_arent_xml_to_the_parser() {
        // HTML, with unclosed elements
        let html = format!("<html><body>{}</body></html>", "line<br>".repeat(2000));
        assert!(check_xml(html.as_bytes()).is_ok());

        // A Typst file that starts with a label
        let typst = format!("<intro>\n{}", "= Heading <label>\n".repeat(2000));
        assert!(check_xml(typst.as_bytes()).is_ok());
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

        // A long name is counted like a short one
        let name = "n".repeat(300);
        let references = format!("&{name};").repeat(300);
        let long_names =
            format!("<!DOCTYPE a [ <!ENTITY {name} \"{value}\"> ]><a>{references}</a>");
        assert!(check_xml(long_names.as_bytes()).is_err());

        // Unterminated declarations don't confuse the scan
        assert!(check_xml(br#"<!DOCTYPE a [<!ENTITY x "unterminated"#).is_ok());
    }

    #[test]
    fn checks_images_in_svg_data_urls() {
        // A PNG header claiming 1,000,000 × 2,000,000,000 pixels
        let mut png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR".to_vec();
        png.extend_from_slice(&1_000_000u32.to_be_bytes());
        png.extend_from_slice(&2_000_000_000u32.to_be_bytes());
        png.extend_from_slice(&[8, 6, 0, 0, 0, 0, 0, 0, 0]);

        let svg = format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg"><image href="data:image/png;base64,{}"/></svg>"#,
            base64(&png)
        );
        assert!(check(svg.as_bytes(), Some("svg"))
            .unwrap_err()
            .contains("too large"));

        let nested = format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg"><image href="data:image/svg+xml;base64,{}"/></svg>"#,
            base64(b"<svg xmlns='http://www.w3.org/2000/svg'/>")
        );
        assert!(check(nested.as_bytes(), Some("svg")).is_err());
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
        assert!(check(b"\x1f\x8b%PDF-1.7", Some("pdf")).is_err());
        assert!(check(b"no header\n1 0 obj << >> endobj", Some("dat")).is_err());
        assert!(check(b"name,price\nBMW,1", Some("csv")).is_ok());
    }

    #[test]
    fn refuses_cbor_that_declares_too_many_items() {
        let mut array = vec![0x9B];
        array.extend_from_slice(&(1u64 << 44).to_be_bytes());
        assert!(check(&array, Some("cbor")).is_err());
        assert!(check(&array, None).is_err());

        // Nested inside an array of two
        let mut nested = vec![0x82, 0x01, 0xBB];
        nested.extend_from_slice(&(1u64 << 40).to_be_bytes());
        assert!(check(&nested, Some("cbor")).is_err());

        // [1, [2, 3], {"a": 4}] and an indefinite-length array
        let valid = [0x83, 0x01, 0x82, 0x02, 0x03, 0xA1, 0x61, b'a', 0x04];
        assert!(check(&valid, Some("cbor")).is_ok());
        assert!(check(&[0x9F, 0x01, 0x02, 0xFF], Some("cbor")).is_ok());

        // Text isn't taken for CBOR
        assert!(check(b"xy", None).is_ok());
    }

    #[test]
    fn refuses_deeply_nested_bibliographies() {
        let deep = format!(
            "@misc{{key, title = {}{}}}",
            "{".repeat(1000),
            "}".repeat(1000)
        );
        assert!(check(deep.as_bytes(), Some("bib")).is_err());
        assert!(check(b"@misc{key, title = {A {B} C}}", Some("bib")).is_ok());

        let yaml = format!("key: {}{}", "[".repeat(1000), "]".repeat(1000));
        assert!(check(yaml.as_bytes(), Some("yml")).is_err());
    }
}
