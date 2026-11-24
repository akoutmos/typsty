//! Checks on the files a document reads, before Typst decodes them.
//!
//! Typst decodes images into memory at the size their header claims, and a small file can
//! claim to be enormous. Allocating that fails, and a failed allocation aborts the VM. It
//! also parses SVG and XML files recursively, so a deeply nested file can overflow the
//! stack. These checks reject such files with an error instead.

/// The most pixels an image may have: 2^27, about 134 megapixels, which takes 512 MiB
/// decoded (Typst's own limit for some formats).
pub const MAX_IMAGE_PIXELS: u64 = 1 << 27;

/// How deeply the elements of an SVG or XML file may be nested.
pub const MAX_XML_DEPTH: usize = 1024;

/// Checks a file's contents. Returns a description of the problem for a file that's unsafe
/// to give to Typst.
pub fn check(bytes: &[u8]) -> Result<(), String> {
    check_image_size(bytes)?;
    check_xml_depth(bytes)
}

fn check_image_size(bytes: &[u8]) -> Result<(), String> {
    // Only images with a recognizable header are checked; anything else isn't an image
    // Typst can decode either
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

/// Measures how deeply elements are nested in content that looks like XML (or SVG). This is a
/// rough scan, not a parser: it only needs to find files that nest too deeply.
fn check_xml_depth(bytes: &[u8]) -> Result<(), String> {
    let content = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(bytes);
    let start = content
        .iter()
        .position(|byte| !byte.is_ascii_whitespace())
        .unwrap_or(content.len());

    if content.get(start) != Some(&b'<') {
        return Ok(());
    }

    let mut depth: usize = 0;
    let mut index = start;

    while let Some(offset) = content[index..].iter().position(|&byte| byte == b'<') {
        index += offset;
        let rest = &content[index..];

        if rest.starts_with(b"<!--") {
            index += skip_past(rest, b"-->");
        } else if rest.starts_with(b"<![CDATA[") {
            index += skip_past(rest, b"]]>");
        } else if rest.starts_with(b"<?") {
            index += skip_past(rest, b"?>");
        } else if rest.starts_with(b"<!") {
            // A DOCTYPE, which can have an internal subset in brackets. Every byte is
            // scanned at most twice, so this stays linear.
            let end = skip_past(rest, b">");
            index += if rest[..end].contains(&b'[') {
                skip_past(rest, b"]>")
            } else {
                end
            };
        } else if rest.starts_with(b"</") {
            depth = depth.saturating_sub(1);
            index += skip_past(rest, b">");
        } else {
            let end = tag_end(rest);
            if !rest[..end].ends_with(b"/>") {
                depth += 1;
                if depth > MAX_XML_DEPTH {
                    return Err(format!(
                        "the file's elements are nested more than {MAX_XML_DEPTH} levels deep"
                    ));
                }
            }
            index += end;
        }
    }

    Ok(())
}

/// The length up to and including the first occurrence of `pattern`, or the whole slice.
fn skip_past(bytes: &[u8], pattern: &[u8]) -> usize {
    bytes
        .windows(pattern.len())
        .position(|window| window == pattern)
        .map_or(bytes.len(), |position| position + pattern.len())
}

/// The length of a start tag, up to and including its `>`, skipping quoted attribute values.
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

    #[test]
    fn measures_xml_depth() {
        assert!(check_xml_depth(b"<a><b/><c x='>'><!-- <d> --></c></a>").is_ok());
        assert!(check_xml_depth(b"not xml <<<<").is_ok());

        let deep = "<a>".repeat(MAX_XML_DEPTH + 1);
        assert!(check_xml_depth(deep.as_bytes()).is_err());

        let siblings = "<a></a>".repeat(MAX_XML_DEPTH * 10);
        assert!(check_xml_depth(format!("<r>{siblings}</r>").as_bytes()).is_ok());
    }
}
