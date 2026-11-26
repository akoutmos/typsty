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

/// The longest XML entity name the checks read. Longer names are refused, so that finding
/// entities takes linear time.
const MAX_ENTITY_NAME: usize = 256;

/// The most a PNG's compressed metadata (its color profile and compressed text) may expand
/// to, together: 16 MiB. Typst's PNG decoder decompresses the color profile without a limit.
pub const MAX_PNG_METADATA: u64 = 16 * 1024 * 1024;

/// How many abbreviations, `crossref`s and `xdata`s resolving a BibTeX file may expand.
/// Typst's BibTeX library resolves them recursively, without remembering what it resolved,
/// so a small file can make that exponential (and a cycle overflows the stack).
pub const MAX_BIB_RESOLUTIONS: u64 = 1_000_000;

/// The most text a BibTeX file's abbreviations may expand to: 64 MiB.
pub const MAX_BIB_EXPANSION: u64 = 64 * 1024 * 1024;

/// How far an SVG's content may reach from its canvas, as a multiple of its size. Typst's
/// PDF and PNG libraries abort on geometry far outside it (a panic while they unwind from
/// another), and legitimate drawings stay close to their canvas.
const MAX_SVG_REACH: f32 = 1000.0;

/// File extensions Typst reads as data (or text), and only decodes as a PDF when a template
/// asks for that with `format: "pdf"`.
const DATA_EXTENSIONS: &[&str] = &[
    "csv", "tsv", "json", "yaml", "yml", "toml", "txt", "xml", "bib", "typ", "csl", "md", "html",
    "htm", "cbor",
];

/// File extensions that decide the format Typst decodes an image in, rather than its
/// contents.
const IMAGE_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "gif", "webp", "svg", "svgz"];

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
    check_png_metadata(bytes)?;
    check_cbor(bytes, extension)?;
    check_brackets(bytes, extension)?;
    check_bib(bytes, extension)?;
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
    // near the start of a file whose extension doesn't decide its format, or when a template
    // asks for one with `format: "pdf"`. Its decoder doesn't need the header, but every PDF
    // it can decode has objects, which end with `endobj`: files that might be decoded as a
    // PDF are refused when they have one, unless they're data files, which a template would
    // have to ask to decode as a PDF on purpose
    let image = has_extension(extension, IMAGE_EXTENSIONS);
    let data = has_extension(extension, DATA_EXTENSIONS);
    let head = &bytes[..bytes.len().min(DETECTION_WINDOW)];
    let pdf = has_extension(extension, &["pdf"])
        || (!image && memchr::memmem::find(head, b"%PDF-").is_some())
        || (!image && !data && memchr::memmem::find(bytes, b"endobj").is_some());

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

    if size.width == 0 || size.height == 0 {
        return Err(format!(
            "the image has no pixels ({} × {})",
            size.width, size.height
        ));
    }

    let pixels = (size.width as u64).saturating_mul(size.height as u64);
    if pixels > MAX_IMAGE_PIXELS {
        return Err(format!(
            "the image is too large to decode: {} × {} pixels (at most {MAX_IMAGE_PIXELS} pixels)",
            size.width, size.height
        ));
    }

    Ok(())
}

/// A PNG's color profile (`iCCP`) and compressed text (`zTXt`, `iTXt`) are zlib streams,
/// which a small file can make expand a thousandfold. Typst's PNG decoder decompresses the
/// color profile without a limit.
fn check_png_metadata(bytes: &[u8]) -> Result<(), String> {
    const SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";

    let Some(mut rest) = bytes.strip_prefix(SIGNATURE) else {
        return Ok(());
    };

    let mut expanded: u64 = 0;

    while rest.len() >= 8 {
        let length = u32::from_be_bytes([rest[0], rest[1], rest[2], rest[3]]) as usize;
        let kind = &rest[4..8];
        let data = &rest[8..rest.len().min(8usize.saturating_add(length))];

        // After the keyword (and its terminator): the compression method, or for iTXt,
        // whether it's compressed, the method, a language tag and a translated keyword
        let compressed = match kind {
            b"iCCP" | b"zTXt" => after_nul(data).and_then(|rest| rest.get(1..)),
            b"iTXt" => after_nul(data)
                .filter(|rest| rest.first() == Some(&1))
                .and_then(|rest| rest.get(2..))
                .and_then(after_nul)
                .and_then(after_nul),
            b"IEND" => break,
            _ => None,
        };

        if let Some(stream) = compressed {
            let limit = MAX_PNG_METADATA - expanded;
            let mut decoder = flate2::read::ZlibDecoder::new(stream).take(limit + 1);
            expanded += std::io::copy(&mut decoder, &mut std::io::sink()).unwrap_or(0);

            if expanded > MAX_PNG_METADATA {
                return Err(format!(
                    "the image's color profile and metadata expand to more than {} MiB",
                    MAX_PNG_METADATA / 1024 / 1024
                ));
            }
        }

        // The length, type, data and checksum
        rest = rest.get(length.saturating_add(12)..).unwrap_or(&[]);
    }

    Ok(())
}

fn after_nul(bytes: &[u8]) -> Option<&[u8]> {
    memchr::memchr(0, bytes).map(|position| &bytes[position + 1..])
}

/// Typst's BibTeX library resolves `@string` abbreviations, and the entries named by
/// `crossref` and `xdata` fields, recursively and without remembering what it resolved: a
/// cycle overflows the stack, and a small file can make the work exponential. The file is
/// parsed the way the library parses it, and the references are followed here without
/// recursion, counting the work.
fn check_bib(bytes: &[u8], extension: Option<&str>) -> Result<(), String> {
    use biblatex::{RawBibliography, RawChunk};

    if !has_extension(extension, &["bib"]) {
        return Ok(());
    }

    let Ok(text) = std::str::from_utf8(bytes) else {
        return Ok(());
    };
    let Ok(raw) = RawBibliography::parse(text) else {
        return Ok(());
    };

    // Abbreviations, of which the last one with a name is the one used, as in the library
    let names: HashMap<&str, usize> = raw
        .abbreviations
        .iter()
        .enumerate()
        .map(|(index, pair)| (pair.key.v, index))
        .collect();

    let references: Vec<Vec<usize>> = raw
        .abbreviations
        .iter()
        .map(|pair| {
            pair.value
                .v
                .iter()
                .filter_map(|chunk| match chunk.v {
                    RawChunk::Abbreviation(name) => names.get(name).copied(),
                    RawChunk::Normal(_) => None,
                })
                .collect()
        })
        .collect();

    let Some(order) = dependencies_first(&references) else {
        return Err(
            "the bibliography's @string abbreviations refer to each other in a cycle".into(),
        );
    };

    // How many chunks resolving each abbreviation expands, and the length of its text
    let mut work = vec![0u64; references.len()];
    let mut length = vec![0u64; references.len()];
    for index in order {
        let (chunk_work, chunk_length) =
            field_size(&raw.abbreviations[index].value.v, &names, &work, &length);
        work[index] = chunk_work.saturating_add(1);
        length[index] = chunk_length;
    }

    let (mut total_work, mut total_length) = (0u64, 0u64);
    for entry in &raw.entries {
        for field in &entry.v.fields {
            let (field_work, field_length) = field_size(&field.value.v, &names, &work, &length);
            total_work = total_work.saturating_add(field_work);
            total_length = total_length.saturating_add(field_length);
        }
    }

    if total_work > MAX_BIB_RESOLUTIONS || total_length > MAX_BIB_EXPANSION {
        return Err(
            "the bibliography's @string abbreviations expand too much (more than 64 MiB, or a million times)".into(),
        );
    }

    // Entries, by key, and the entries their crossref and xdata fields name
    let keys: HashMap<&str, usize> = raw
        .entries
        .iter()
        .enumerate()
        .map(|(index, entry)| (entry.v.key.v, index))
        .collect();

    let references: Vec<Vec<usize>> = raw
        .entries
        .iter()
        .map(|entry| {
            let mut named = Vec::new();
            for field in &entry.v.fields {
                let key = field.key.v.to_ascii_lowercase();
                if key != "crossref" && key != "xdata" {
                    continue;
                }

                let value = field_text(&field.value.v, &raw.abbreviations, &names);
                for name in value.split(',') {
                    named.extend(keys.get(name.trim()).copied());
                }
            }
            named
        })
        .collect();

    let Some(order) = dependencies_first(&references) else {
        return Err(
            "the bibliography's crossref and xdata fields refer to each other in a cycle".into(),
        );
    };

    // Resolving an entry resolves the entries it names, each time it names them
    let mut work = vec![0u64; references.len()];
    let mut total: u64 = 0;
    for index in order {
        work[index] = references[index]
            .iter()
            .fold(1u64, |sum, named| sum.saturating_add(work[*named]));
        total = total.saturating_add(work[index]);
    }

    if total > MAX_BIB_RESOLUTIONS {
        return Err(format!(
            "the bibliography's crossref and xdata fields take more than {MAX_BIB_RESOLUTIONS} steps to resolve"
        ));
    }

    Ok(())
}

/// The chunks resolving a field expands, and the length of its text.
fn field_size(
    field: &biblatex::Field,
    names: &HashMap<&str, usize>,
    work: &[u64],
    length: &[u64],
) -> (u64, u64) {
    field
        .iter()
        .fold((0u64, 0u64), |(chunks, text), chunk| match chunk.v {
            biblatex::RawChunk::Normal(normal) => (
                chunks.saturating_add(1),
                text.saturating_add(normal.len() as u64),
            ),
            biblatex::RawChunk::Abbreviation(name) => match names.get(name) {
                Some(&index) => (
                    chunks.saturating_add(work[index]),
                    text.saturating_add(length[index]),
                ),
                // A month, or an unknown abbreviation, which is an error
                None => (chunks.saturating_add(1), text.saturating_add(16)),
            },
        })
}

/// A field's text, with abbreviations expanded, up to a few KiB (enough for the keys a
/// crossref or xdata field names). Called once the abbreviations are known to have no cycle.
fn field_text(
    field: &biblatex::Field,
    abbreviations: &[biblatex::Pair],
    names: &HashMap<&str, usize>,
) -> String {
    const LIMIT: usize = 4096;

    let mut text = String::new();
    let mut pending: Vec<&biblatex::RawChunk> = field.iter().rev().map(|chunk| &chunk.v).collect();

    while let Some(chunk) = pending.pop() {
        if text.len() > LIMIT {
            break;
        }

        match chunk {
            biblatex::RawChunk::Normal(normal) => text.push_str(normal),
            biblatex::RawChunk::Abbreviation(name) => match names.get(name) {
                Some(&index) => pending.extend(
                    abbreviations[index]
                        .value
                        .v
                        .iter()
                        .rev()
                        .map(|chunk| &chunk.v),
                ),
                None => text.push_str(name),
            },
        }
    }

    text
}

/// The nodes of a graph (given by the nodes each node refers to) in an order where every
/// node comes after the nodes it refers to, or `None` if the references form a cycle.
fn dependencies_first(references: &[Vec<usize>]) -> Option<Vec<usize>> {
    let mut referrers: Vec<Vec<usize>> = vec![Vec::new(); references.len()];
    let mut unresolved: Vec<usize> = Vec::with_capacity(references.len());

    for (node, named) in references.iter().enumerate() {
        unresolved.push(named.len());
        for &other in named {
            referrers[other].push(node);
        }
    }

    let mut ready: Vec<usize> = (0..references.len())
        .filter(|&node| unresolved[node] == 0)
        .collect();
    let mut order = Vec::with_capacity(references.len());

    while let Some(node) = ready.pop() {
        order.push(node);
        for &referrer in &referrers[node] {
            unresolved[referrer] -= 1;
            if unresolved[referrer] == 0 {
                ready.push(referrer);
            }
        }
    }

    (order.len() == references.len()).then_some(order)
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
    check_data_urls(&document)?;

    if document.root_element().has_tag_name("svg") && !isolated() {
        check_svg_geometry(text)?;
    }

    Ok(())
}

/// Parses an SVG the way Typst does (without its images and fonts), and checks that its
/// transforms are finite and its content stays within `MAX_SVG_REACH` of its canvas.
fn check_svg_geometry(text: &str) -> Result<(), String> {
    let options = usvg::Options {
        image_href_resolver: usvg::ImageHrefResolver {
            resolve_data: Box::new(|_, _, _| None),
            resolve_string: Box::new(|_, _| None),
        },
        ..usvg::Options::default()
    };

    let Ok(tree) = usvg::Tree::from_str(text, &options) else {
        return Ok(());
    };

    let size = tree.size();
    let reach = MAX_SVG_REACH * size.width().max(size.height()).max(1.0);

    let mut groups = vec![tree.root()];
    while let Some(group) = groups.pop() {
        groups.extend(group.clip_path().map(|clip| clip.root()));
        groups.extend(group.mask().map(|mask| mask.root()));

        for node in group.children() {
            let transform = node.abs_transform();
            let bounds = node.abs_bounding_box();

            let finite = [
                transform.sx,
                transform.kx,
                transform.ky,
                transform.sy,
                transform.tx,
                transform.ty,
            ]
            .iter()
            .all(|value| value.is_finite());

            let within = [bounds.left(), bounds.top(), bounds.right(), bounds.bottom()]
                .iter()
                .all(|value| value.is_finite() && value.abs() <= reach);

            if !finite || !within {
                return Err(format!(
                    "the SVG has content more than {MAX_SVG_REACH} times its size away from its canvas, which can't be drawn"
                ));
            }

            if let usvg::Node::Group(group) = node {
                groups.push(group);
            }
        }
    }

    Ok(())
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

            // Like the SVG library, which parses any other text/plain payload as an SVG
            let mime = url.mime_type();
            let raster = matches!(
                imagesize::image_type(&payload),
                Ok(imagesize::ImageType::Png
                    | imagesize::ImageType::Jpeg
                    | imagesize::ImageType::Gif
                    | imagesize::ImageType::Webp)
            );

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

        let window = &rest[..rest.len().min(MAX_ENTITY_NAME + 1)];
        let name_length = window
            .iter()
            .position(|byte| byte.is_ascii_whitespace() || matches!(byte, b'"' | b'\'' | b'>'))
            .unwrap_or(window.len());

        if name_length > MAX_ENTITY_NAME {
            return Err(format!(
                "the file declares an XML entity with a name longer than {MAX_ENTITY_NAME} bytes"
            ));
        }

        let name = &rest[..name_length];
        rest = skip_spaces(&rest[name_length..]);

        if let Some(&quote @ (b'"' | b'\'')) = rest.first() {
            let value = &rest[1..];
            let value = &value[..memchr::memchr(quote, value).unwrap_or(value.len())];

            if !plain_entity_value(value) {
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

    // References to declared entities have names of at most MAX_ENTITY_NAME bytes, so the
    // search for the end of one stops there
    for start in memchr::memchr_iter(b'&', content) {
        let rest = &content[start + 1..];
        let window = &rest[..rest.len().min(MAX_ENTITY_NAME + 1)];
        let Some(end) = memchr::memchr(b';', window) else {
            continue;
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

/// Whether an entity's value is plain text, which only expands to itself. Character
/// references (`&#160;`) are allowed, except to the characters that would make the value
/// markup or an entity reference once it's expanded (`&` and `<`: a `%` only starts a
/// reference in the declarations themselves).
fn plain_entity_value(value: &[u8]) -> bool {
    let mut rest = value;

    while let Some(position) = rest
        .iter()
        .position(|byte| matches!(byte, b'&' | b'%' | b'<'))
    {
        if rest[position] != b'&' {
            return false;
        }

        let reference = &rest[position + 1..];
        let (digits, radix) = match reference {
            [b'#', b'x', digits @ ..] => (digits, 16),
            [b'#', digits @ ..] => (digits, 10),
            _ => return false,
        };

        let length = digits.iter().take(9).position(|byte| *byte == b';');
        let Some(code) = length
            .filter(|length| *length > 0)
            .and_then(|length| std::str::from_utf8(&digits[..length]).ok())
            .and_then(|text| u32::from_str_radix(text, radix).ok())
        else {
            return false;
        };

        rest = &digits[length.unwrap_or(0) + 1..];

        // An ampersand followed by `#` expands to another character reference, which is
        // how XHTML and MathML declare `amp` and `lt` (`&#38;#38;`)
        let escaped_reference = code == 0x26 && rest.first() == Some(&b'#');
        if matches!(code, 0x26 | 0x3C) && !escaped_reference {
            return false;
        }
    }

    true
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

    #[test]
    fn refuses_bibliographies_whose_references_cycle_or_explode() {
        for cyclic in [
            "@book{a, title = {T}, crossref = {a}}",
            "@book{a, crossref = {b}} @book{b, crossref = {a}}",
            "@xdata{a, xdata = {a}} @book{b, title = {T}, xdata = {a}}",
            "@string{a = b} @string{b = a} @book{k, title = a}",
            "@string{key = \"a\"} @book{a, crossref = key}",
        ] {
            assert!(check(cyclic.as_bytes(), Some("bib")).is_err(), "{cyclic}");
        }

        // Each abbreviation twice the one before
        let mut doubling = String::from("@string{s0 = \"aaaaaaaaaaaaaaaa\"}\n");
        for level in 1..40 {
            doubling.push_str(&format!(
                "@string{{s{level} = s{} # s{}}}\n",
                level - 1,
                level - 1
            ));
        }
        doubling.push_str("@book{k, title = s39}");
        assert!(check(doubling.as_bytes(), Some("bib")).is_err());

        // Each entry naming the next twice, which the library resolves 2^30 times
        let mut fan_out = String::new();
        for level in 0..30 {
            fan_out.push_str(&format!(
                "@xdata{{x{level}, xdata = {{x{0}, x{0}}}}}\n",
                level + 1
            ));
        }
        fan_out.push_str("@xdata{x30, note = {N}}");
        assert!(check(fan_out.as_bytes(), Some("bib")).is_err());

        let fine = "@string{acm = \"ACM\"} @proceedings{p, title = {P}, publisher = acm} \
                    @inproceedings{a, title = {A}, crossref = {p}, month = jan}";
        assert!(check(fine.as_bytes(), Some("bib")).is_ok());
    }

    #[test]
    fn scans_entities_in_linear_time() {
        // Many ampersands before the only semicolon, and many long entity names
        let mut ampersands = String::from("<!DOCTYPE a [<!ENTITY e \"v\">]><a>");
        ampersands.push_str(&"&".repeat(2_000_000));
        ampersands.push_str(";</a>");

        let started = std::time::Instant::now();
        assert!(check(ampersands.as_bytes(), Some("xml")).is_ok());
        let names = format!("<a>{}</a>", "<!ENTITY".repeat(1_000_000));
        let _ = check(names.as_bytes(), Some("xml"));
        assert!(started.elapsed() < std::time::Duration::from_secs(5));

        let long_name = format!("<!DOCTYPE a [<!ENTITY {} \"v\">]><a/>", "n".repeat(300));
        assert!(check(long_name.as_bytes(), Some("xml")).is_err());
    }

    #[test]
    fn allows_character_references_in_entities_but_not_markup() {
        let nbsp =
            "<!DOCTYPE a [<!ENTITY nbsp \"&#160;\"><!ENTITY hex \"&#x00A0;\">]><a>&nbsp;&hex;</a>";
        assert!(check(nbsp.as_bytes(), Some("xml")).is_ok());

        // As XHTML and MathML declare them
        let amp = "<!DOCTYPE a [<!ENTITY amp \"&#38;#38;\"><!ENTITY nvlt \"&#38;#x0003C;&#x020D2;\">]><a>&amp;</a>";
        assert!(check(amp.as_bytes(), Some("xml")).is_ok());

        // An ampersand or a bracket would make the expanded value a reference or markup
        for value in [
            "&#38;e;", "&#x26;e;", "&#60;a/>", "%e;", "&e;", "&#;", "&#xZZ;",
        ] {
            let xml = format!("<!DOCTYPE a [<!ENTITY e \"{value}\">]><a/>");
            assert!(check(xml.as_bytes(), Some("xml")).is_err(), "{value}");
        }
    }

    #[test]
    fn treats_text_data_urls_that_arent_images_as_svgs() {
        // Valid XML that imagesize takes for an AVIF image, which the SVG library parses as
        // an SVG
        let inner = r#"<!--ftypavif--><svg xmlns="http://www.w3.org/2000/svg"/>"#;
        let svg = format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg"><image href="data:text/plain;base64,{}"/></svg>"#,
            base64(inner.as_bytes())
        );
        assert!(check(svg.as_bytes(), Some("svg")).is_err());
    }

    #[test]
    fn refuses_png_metadata_that_expands_too_much() {
        let mut deflate = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::best());
        std::io::Write::write_all(&mut deflate, &vec![0; 20 * 1024 * 1024]).unwrap();
        let profile = [b"icc\0\0".as_slice(), &deflate.finish().unwrap()].concat();

        let chunk = |kind: &[u8], data: &[u8]| {
            [&(data.len() as u32).to_be_bytes()[..], kind, data, &[0; 4]].concat()
        };
        let png = |profile: &[u8]| {
            [
                b"\x89PNG\r\n\x1a\n".as_slice(),
                &chunk(b"IHDR", &[0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0]),
                &chunk(b"iCCP", profile),
                &chunk(b"IEND", &[]),
            ]
            .concat()
        };

        assert!(check(&png(&profile), Some("png")).is_err());

        let mut small = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::best());
        std::io::Write::write_all(&mut small, &[0; 3144]).unwrap();
        let profile = [b"icc\0\0".as_slice(), &small.finish().unwrap()].concat();
        assert!(check(&png(&profile), Some("png")).is_ok());
    }

    #[test]
    fn refuses_images_without_pixels() {
        let gif = [b"GIF89a".as_slice(), &[0, 0, 1, 0, 0, 0, 0], b";"].concat();
        assert!(check(&gif, Some("gif")).is_err());
    }

    #[test]
    fn only_looks_for_pdf_objects_where_a_pdf_could_be_decoded() {
        assert!(check(b"name,value\nendobj,1\n", Some("csv")).is_ok());
        assert!(check(b"endobj", Some("txt")).is_ok());
        assert!(check(
            b"<svg xmlns=\"http://www.w3.org/2000/svg\"><!-- %PDF- --></svg>",
            Some("svg")
        )
        .is_ok());
        assert!(check(b"1 0 obj << >> endobj", None).is_err());
        assert!(check(b"%PDF-1.7", Some("bin")).is_err());
    }

    #[test]
    fn refuses_svgs_with_geometry_far_from_their_canvas() {
        // Nested viewBoxes that scale by 10^10 each, and a curve 3 × 10^12 units away
        let scaled = r#"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><svg width="1e5" height="1e5" viewBox="0 0 0.00001 0.00001"><svg width="1e5" height="1e5" viewBox="0 0 0.00001 0.00001"><rect width="50" height="50"/></svg></svg></svg>"#;
        let far = r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><path d="M0 0c15 15 20 39 12 59s-18-18-13-3e12"/></svg>"#;
        assert!(check(scaled.as_bytes(), Some("svg")).is_err());
        assert!(check(far.as_bytes(), Some("svg")).is_err());

        let fine = r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="240"><g transform="scale(2)"><path d="M-10 -10 L 30 30"/></g></svg>"#;
        assert!(check(fine.as_bytes(), Some("svg")).is_ok());
    }
}
