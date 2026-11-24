//! Font discovery, cached for the life of the VM.
//!
//! Scanning the system fonts takes a while, so each combination of font settings is scanned
//! once and the resulting store is shared by every render that uses the same settings. Fonts
//! themselves are loaded lazily by the store, the first time a document uses them.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, LazyLock, Mutex};

use typst_kit::fonts::FontStore;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct FontSettings {
    /// Directories to scan for fonts, recursively. Kept sorted, so the order they're given
    /// in doesn't create separate cache entries.
    pub font_paths: Vec<String>,
    /// Whether to include the fonts installed on the system.
    pub system_fonts: bool,
    /// Whether to include the fonts embedded in Typst (Libertinus Serif, New Computer
    /// Modern, New Computer Modern Math and DejaVu Sans Mono).
    pub embedded_fonts: bool,
}

impl FontSettings {
    pub fn new(mut font_paths: Vec<String>, system_fonts: bool, embedded_fonts: bool) -> Self {
        font_paths.sort();
        font_paths.dedup();

        Self {
            font_paths,
            system_fonts,
            embedded_fonts,
        }
    }
}

static FONT_STORES: LazyLock<Mutex<HashMap<FontSettings, Arc<FontStore>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Returns the font store for the settings, scanning for fonts the first time.
pub fn store(settings: &FontSettings) -> Arc<FontStore> {
    let mut stores = FONT_STORES
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    stores
        .entry(settings.clone())
        .or_insert_with(|| Arc::new(build(settings)))
        .clone()
}

fn build(settings: &FontSettings) -> FontStore {
    let mut store = FontStore::new();

    // Fonts from the given paths come first, so that they take precedence over system fonts
    // with the same name
    for path in &settings.font_paths {
        store.extend(typst_kit::fonts::scan(Path::new(path)));
    }

    if settings.system_fonts {
        store.extend(typst_kit::fonts::system());
    }

    if settings.embedded_fonts {
        store.extend(typst_kit::fonts::embedded());
    }

    store
}
