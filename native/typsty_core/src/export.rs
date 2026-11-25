//! Exports compiled documents to PDF, PNG and SVG.

use typst::foundations::Smart;
use typst::layout::{Frame, FrameItem, FrameKind, Ratio, Size, Transform};
use typst::text::TextItem;
use typst::utils::Scalar;
use typst::visualize::{Paint, RelativeTo, Tiling};
use typst_layout::{Page, PagedDocument};
use typst_pdf::{PdfOptions, PdfStandard, PdfStandards, Timestamp};

use crate::diagnostics::{self, Diagnostic};
use crate::world::TypstyWorld;

/// The most pixels rasterizing a page may take, for the page itself and for the images,
/// gradients and tilings on it: 2^28 pixels, which is 1 GiB of textures. Typst sizes these by
/// the content, so content placed far outside the page, or an extreme `:ppi`, could otherwise
/// ask for more memory than exists, and a failed allocation aborts the VM. (Resizing images
/// and encoding the page take memory on top of this, a few times as much at worst.)
pub const MAX_PNG_PIXELS: f64 = (1u64 << 28) as f64;

pub enum Output {
    Pdf(Vec<u8>),
    Pages(Vec<Vec<u8>>),
}

pub fn pdf(
    document: &PagedDocument,
    standards: PdfStandards,
    world: &TypstyWorld,
) -> Result<Output, Vec<Diagnostic>> {
    let options = PdfOptions {
        standards,
        // Without an identifier, Typst derives one from the document's title and author
        ident: Smart::Auto,
        // Like the Typst CLI, `set document(date: auto)` (the default) is the time of the
        // render. Templates set `date: none` to leave it out, for reproducible PDFs.
        timestamp: Some(Timestamp::new_utc(world.now())),
        ..PdfOptions::default()
    };

    typst_pdf::pdf(document, &options)
        .map(Output::Pdf)
        .map_err(|errors| diagnostics::from_sources(&errors, world))
}

pub fn png(
    document: &PagedDocument,
    ppi: f64,
    world: &TypstyWorld,
) -> Result<Output, Vec<Diagnostic>> {
    let pixel_per_pt = ppi / 72.0;
    let options = typst_render::RenderOptions {
        pixel_per_pt: Scalar::new(pixel_per_pt),
        ..typst_render::RenderOptions::default()
    };

    let mut pages = Vec::with_capacity(document.pages().len());

    for (index, page) in document.pages().iter().enumerate() {
        world.check_cancelled();

        check_raster_size(page, pixel_per_pt).map_err(|problem| {
            vec![Diagnostic::error(format!(
                "page {} can't be rendered as a PNG at {ppi} ppi: {problem}",
                index + 1
            ))]
        })?;

        let png = typst_render::render(page, &options)
            .encode_png()
            .map_err(|error| {
                vec![Diagnostic::error(format!(
                    "failed to encode page {} as PNG: {error}",
                    index + 1
                ))]
            })?;

        pages.push(png);
    }

    Ok(Output::Pages(pages))
}

pub fn svg(document: &PagedDocument, world: &TypstyWorld) -> Output {
    let options = typst_svg::SvgOptions::default();

    Output::Pages(
        document
            .pages()
            .iter()
            .map(|page| {
                world.check_cancelled();
                typst_svg::svg(page, &options).into_bytes()
            })
            .collect(),
    )
}

/// The PDF standards named in the `:pdf_standards` option, checked for conflicts.
pub fn pdf_standards(names: &[String]) -> Result<PdfStandards, String> {
    let standards = names
        .iter()
        .map(|name| pdf_standard(name))
        .collect::<Result<Vec<_>, _>>()?;

    PdfStandards::new(&standards)
        .map_err(|error| format!("invalid :pdf_standards option: {}", error.message()))
}

fn pdf_standard(name: &str) -> Result<PdfStandard, String> {
    Ok(match name {
        "1.4" => PdfStandard::V_1_4,
        "1.5" => PdfStandard::V_1_5,
        "1.6" => PdfStandard::V_1_6,
        "1.7" => PdfStandard::V_1_7,
        "2.0" => PdfStandard::V_2_0,
        "a-1b" => PdfStandard::A_1b,
        "a-1a" => PdfStandard::A_1a,
        "a-2b" => PdfStandard::A_2b,
        "a-2u" => PdfStandard::A_2u,
        "a-2a" => PdfStandard::A_2a,
        "a-3b" => PdfStandard::A_3b,
        "a-3u" => PdfStandard::A_3u,
        "a-3a" => PdfStandard::A_3a,
        "a-4" => PdfStandard::A_4,
        "a-4f" => PdfStandard::A_4f,
        "a-4e" => PdfStandard::A_4e,
        "ua-1" => PdfStandard::Ua_1,
        other => {
            return Err(format!(
                "unknown PDF standard in the :pdf_standards option: {other:?}. The standards are \"1.4\" to \"1.7\", \"2.0\", \"a-1b\", \"a-1a\", \"a-2b\", \"a-2u\", \"a-2a\", \"a-3b\", \"a-3u\", \"a-3a\", \"a-4\", \"a-4f\", \"a-4e\" and \"ua-1\""
            ))
        }
    })
}

/// Checks that rasterizing the page stays within `MAX_PNG_PIXELS`, by adding up the pixmaps
/// typst-render would allocate for it: the page's canvas, and a texture for each image
/// (at its size on the page, even the part outside the page), gradient, tiling and color
/// glyph. The sizes follow typst-render's own calculations, rounded up.
fn check_raster_size(page: &Page, pixel_per_pt: f64) -> Result<(), String> {
    let size = page.frame.size();
    let mut budget = Budget::default();

    budget.add(
        "the page",
        (size.x.to_pt() * pixel_per_pt).round().max(1.0),
        (size.y.to_pt() * pixel_per_pt).round().max(1.0),
    )?;

    // The page's own fill is painted like a shape the size of the page
    if let Some(fill) = page.fill_or_white() {
        let page_size = (size.x.to_pt(), size.y.to_pt());
        check_paint(&fill, page_size, false, size, pixel_per_pt, &mut budget)?;
    }

    let scale = Transform::scale(Ratio::new(pixel_per_pt), Ratio::new(pixel_per_pt));
    walk(&page.frame, scale, size, pixel_per_pt, &mut budget)
}

#[derive(Default)]
struct Budget {
    pixels: f64,
}

impl Budget {
    fn add(&mut self, what: &str, width: f64, height: f64) -> Result<(), String> {
        let pixels = width.abs() * height.abs();
        self.pixels += pixels;

        if !pixels.is_finite() || !self.pixels.is_finite() || self.pixels > MAX_PNG_PIXELS {
            return Err(format!(
                "{what} needs a {width:.0} × {height:.0} pixel image, which together with the rest of the page is more than {MAX_PNG_PIXELS} pixels. Lower the :ppi, or make the content smaller"
            ));
        }

        Ok(())
    }
}

/// Adds up the frame's textures. `container` is the size of the nearest hard frame it's in
/// (the page, a block or a box), which is what gradients relative to their parent are sized
/// by.
fn walk(
    frame: &Frame,
    ts: Transform,
    container: Size,
    pixel_per_pt: f64,
    budget: &mut Budget,
) -> Result<(), String> {
    for (_position, item) in frame.items() {
        match item {
            FrameItem::Group(group) => {
                let container = match group.frame.kind() {
                    FrameKind::Hard => group.frame.size(),
                    FrameKind::Soft => container,
                };

                walk(
                    &group.frame,
                    ts.pre_concat(group.transform),
                    container,
                    pixel_per_pt,
                    budget,
                )?;
            }
            FrameItem::Image(image, size, _span) => {
                // typst-render resizes the image to its size on the page, in pixels
                let theta = (-ts.kx.get()).atan2(ts.sx.get());
                let scale_x = if theta.sin().abs() > std::f64::consts::FRAC_1_SQRT_2 {
                    (ts.kx.get() / theta.sin()).abs()
                } else {
                    (ts.sx.get() / theta.cos()).abs()
                };

                let aspect = image.width() / image.height();
                let width = (scale_x * size.x.to_pt().max(aspect * size.y.to_pt())).ceil();
                budget.add("an image", width, (width / aspect).ceil())?;
            }
            FrameItem::Shape(shape, _span) => {
                let bbox = shape.bbox(true).size();
                let paints = shape
                    .fill
                    .iter()
                    .chain(shape.stroke.iter().map(|stroke| &stroke.paint));

                for paint in paints {
                    let size = (bbox.x.to_pt(), bbox.y.to_pt());
                    check_paint(paint, size, false, container, pixel_per_pt, budget)?;
                }
            }
            FrameItem::Text(text) => check_text(text, container, ts, pixel_per_pt, budget)?,
            FrameItem::Link(..) | FrameItem::Tag(..) => {}
        }
    }

    Ok(())
}

fn check_text(
    text: &TextItem,
    container: Size,
    ts: Transform,
    pixel_per_pt: f64,
    budget: &mut Budget,
) -> Result<(), String> {
    // Color glyphs (such as emoji) are drawn as images at the text's size
    let scale = ts
        .sx
        .get()
        .abs()
        .max(ts.sy.get().abs())
        .max(ts.kx.get().abs())
        .max(ts.ky.get().abs());
    let em = (text.size.to_pt() * scale).ceil();
    if em * em > MAX_PNG_PIXELS {
        budget.add("text", em, em)?;
    }

    let size = (text.width().to_pt(), text.size.to_pt());
    let paints = std::iter::once(&text.fill).chain(text.stroke.iter().map(|stroke| &stroke.paint));

    for paint in paints {
        check_paint(paint, size, true, container, pixel_per_pt, budget)?;
    }

    Ok(())
}

/// Gradients are sampled into a texture the size of the item (or of the hard frame it's in,
/// for a gradient relative to its parent), and tilings into a texture the size of one tile.
fn check_paint(
    paint: &Paint,
    (width, height): (f64, f64),
    on_text: bool,
    container: Size,
    pixel_per_pt: f64,
    budget: &mut Budget,
) -> Result<(), String> {
    match paint {
        Paint::Solid(_) => Ok(()),
        Paint::Gradient(gradient) => {
            let (width, height) = match gradient.unwrap_relative(on_text) {
                RelativeTo::Self_ => (width, height),
                RelativeTo::Parent => (container.x.to_pt(), container.y.to_pt()),
            };

            budget.add(
                "a gradient",
                (width * pixel_per_pt).ceil().max(pixel_per_pt.ceil()),
                (height * pixel_per_pt).ceil().max(pixel_per_pt.ceil()),
            )
        }
        Paint::Tiling(tiling) => check_tiling(tiling, pixel_per_pt, budget),
    }
}

fn check_tiling(tiling: &Tiling, pixel_per_pt: f64, budget: &mut Budget) -> Result<(), String> {
    let size = tiling.size() + tiling.spacing();
    budget.add(
        "a tiling",
        (size.x.to_pt() * pixel_per_pt).round(),
        (size.y.to_pt() * pixel_per_pt).round(),
    )?;

    // The tile's content is rendered at the page's resolution
    let scale = Transform::scale(Ratio::new(pixel_per_pt), Ratio::new(pixel_per_pt));
    walk(
        tiling.frame(),
        scale,
        tiling.frame().size(),
        pixel_per_pt,
        budget,
    )
}
