//! Links to URLs in exported PDFs and SVGs.
//!
//! Typst writes a link's URL into the document as it is, so a URL from a template's data
//! could be a `javascript:` URL, which runs in the browser of whoever clicks the link in an
//! SVG (or a PDF viewer that hands it to a browser), or a URL for another program on their
//! computer. Links to URLs whose scheme isn't one of `SCHEMES` are left out of the document,
//! with a warning.
//!
//! typst-svg also writes URLs and labels into XML attributes escaping only quotes, so an `&`
//! or `<` in them would make the SVG invalid, and a character reference such as `&#58;`
//! would become part of the URL a browser reads. They're escaped here first.

use std::borrow::Cow;
use std::collections::BTreeSet;

use typst::ecow::EcoVec;
use typst::layout::{Frame, FrameItem};
use typst::model::{Destination, Document, Url};
use typst_layout::{Page, PagedDocument};

use crate::diagnostics::Diagnostic;

/// The schemes links may use. Links without a scheme (relative URLs) are kept too.
pub const SCHEMES: [&str; 4] = ["http", "https", "mailto", "tel"];

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Target {
    Pdf,
    Svg,
}

/// The document, if any of its links had to change for a PDF.
pub fn for_pdf(document: &PagedDocument, warnings: &mut Vec<Diagnostic>) -> Option<PagedDocument> {
    let mut removed = BTreeSet::new();

    if !document
        .pages()
        .iter()
        .any(|page| needs_changes(&page.frame, Target::Pdf))
    {
        return None;
    }

    let pages: EcoVec<Page> = document
        .pages()
        .iter()
        .map(|page| change_page(page, Target::Pdf, &mut removed).into_owned())
        .collect();

    warn(removed, warnings);
    Some(PagedDocument::new(pages, document.info().clone()))
}

/// The page, with its links changed for an SVG if they need to be.
pub fn for_svg<'a>(page: &'a Page, warnings: &mut Vec<Diagnostic>) -> Cow<'a, Page> {
    let mut removed = BTreeSet::new();
    let page = change_page(page, Target::Svg, &mut removed);
    warn(removed, warnings);
    page
}

fn change_page<'a>(
    page: &'a Page,
    target: Target,
    removed: &mut BTreeSet<String>,
) -> Cow<'a, Page> {
    if !needs_changes(&page.frame, target) {
        return Cow::Borrowed(page);
    }

    let mut page = page.clone();
    change(&mut page.frame, target, removed);
    Cow::Owned(page)
}

// Checked before changing anything, since changing a frame copies it
fn needs_changes(frame: &Frame, target: Target) -> bool {
    frame.items().any(|(_, item)| match item {
        FrameItem::Group(group) => {
            (target == Target::Svg
                && group
                    .label
                    .is_some_and(|label| needs_escaping(label.resolve().as_str())))
                || needs_changes(&group.frame, target)
        }
        FrameItem::Link(Destination::Url(url), _) => {
            disallowed_scheme(url).is_some() || (target == Target::Svg && needs_escaping(url))
        }
        _ => false,
    })
}

fn change(frame: &mut Frame, target: Target, removed: &mut BTreeSet<String>) {
    frame.retain(|item| match item {
        FrameItem::Group(group) => {
            // Labels only become an attribute that tools can read, so one that would need
            // escaping is left out
            if target == Target::Svg
                && group
                    .label
                    .is_some_and(|label| needs_escaping(label.resolve().as_str()))
            {
                group.label = None;
            }

            if needs_changes(&group.frame, target) {
                change(&mut group.frame, target, removed);
            }

            true
        }
        FrameItem::Link(destination, _) => {
            let Destination::Url(url) = destination else {
                return true;
            };

            if let Some(scheme) = disallowed_scheme(url) {
                removed.insert(scheme);
                return false;
            }

            if target == Target::Svg && needs_escaping(url) {
                // Typst limits URLs to 8,000 bytes, which escaping may go over
                match Url::new(escape(url)) {
                    Ok(escaped) => *destination = Destination::Url(escaped),
                    Err(_) => return false,
                }
            }

            true
        }
        _ => true,
    });
}

fn warn(removed: BTreeSet<String>, warnings: &mut Vec<Diagnostic>) {
    for scheme in removed {
        let scheme: String = scheme.chars().take(40).collect();

        warnings.push(Diagnostic::warning(format!(
            "a link to a {scheme}: URL was left out of the document: links can only go to http, https, mailto and tel URLs"
        )));
    }
}

/// The URL's scheme, lowercased, when it has one that isn't allowed. Like a browser, it
/// ignores leading and trailing spaces and control characters, and tabs and newlines
/// anywhere.
fn disallowed_scheme(url: &str) -> Option<String> {
    let mut scheme = String::new();

    for c in url
        .trim_matches(|c: char| c <= ' ')
        .chars()
        .filter(|c| !matches!(c, '\t' | '\n' | '\r'))
    {
        match c {
            ':' if !scheme.is_empty() => {
                return (!SCHEMES.contains(&scheme.as_str())).then_some(scheme);
            }
            c if c.is_ascii_alphabetic() => scheme.push(c.to_ascii_lowercase()),
            c if !scheme.is_empty() && (c.is_ascii_digit() || matches!(c, '+' | '-' | '.')) => {
                scheme.push(c)
            }
            // A relative URL
            _ => return None,
        }
    }

    None
}

fn needs_escaping(text: &str) -> bool {
    text.contains(['&', '<', '>'])
}

// Quotes are escaped by typst-svg
fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_web_mail_and_phone_links_and_relative_ones() {
        for url in [
            "https://example.com/?a=1&b=2",
            "HTTP://example.com",
            "mailto:a@example.com",
            "tel:+15555550100",
            "/invoices/42",
            "#total",
            "invoice.pdf",
            "?page=2",
            "//example.com",
            "javascript&#58;alert(1)",
        ] {
            assert_eq!(disallowed_scheme(url), None, "{url}");
        }
    }

    #[test]
    fn finds_other_schemes_as_a_browser_reads_them() {
        for (url, scheme) in [
            ("javascript:alert(1)", "javascript"),
            ("JavaScript:alert(1)", "javascript"),
            ("  \u{0}javascript:alert(1)", "javascript"),
            ("java\tscr\nipt:alert(1)", "javascript"),
            ("data:text/html,<script>alert(1)</script>", "data"),
            ("file:///etc/passwd", "file"),
            ("vbscript:msgbox", "vbscript"),
            ("ms-msdt:/id", "ms-msdt"),
            ("C:\\Windows", "c"),
        ] {
            assert_eq!(disallowed_scheme(url).as_deref(), Some(scheme), "{url}");
        }
    }

    #[test]
    fn escapes_what_typst_svg_does_not() {
        assert_eq!(
            escape("https://a.com/?a=1&b=<2>"),
            "https://a.com/?a=1&amp;b=&lt;2&gt;"
        );
        assert!(!needs_escaping("https://a.com/\"x\""));
    }
}
