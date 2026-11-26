//! Font discovery, cached for the life of the VM.
//!
//! Scanning the system fonts takes a while, so each combination of font settings is scanned
//! once and the resulting store is shared by every render that uses the same settings. Fonts
//! themselves are loaded lazily by the store, the first time a document uses them.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, LazyLock, Mutex, OnceLock, PoisonError};

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

/// A store per font settings, with when it was last used. The map's lock is only held to find
/// a store's cell, so that scanning for one settings' fonts doesn't block renders that use
/// other settings.
struct Stores {
    stores: HashMap<FontSettings, (Cell, u64)>,
    uses: u64,
}

/// Where a store goes once its fonts are scanned.
type Cell = Arc<OnceLock<Arc<FontStore>>>;

static FONT_STORES: LazyLock<Mutex<Stores>> = LazyLock::new(|| {
    Mutex::new(Stores {
        stores: HashMap::new(),
        uses: 0,
    })
});

/// How many font settings are cached. Each store holds the metadata of every font it found,
/// so settings that change from render to render would otherwise grow the cache forever.
const MAX_STORES: usize = 32;

/// Returns the font store for the settings, scanning for fonts the first time.
pub fn store(settings: &FontSettings) -> Arc<FontStore> {
    let cell = {
        let mut stores = FONT_STORES.lock().unwrap_or_else(PoisonError::into_inner);
        let Stores { stores, uses } = &mut *stores;
        *uses += 1;

        // The least recently used settings make room. Renders that are using its store keep
        // it alive until they finish
        if stores.len() >= MAX_STORES && !stores.contains_key(settings) {
            let oldest = stores
                .iter()
                .min_by_key(|(_, (_, used))| *used)
                .map(|(settings, _)| settings.clone());

            if let Some(oldest) = oldest {
                stores.remove(&oldest);
            }
        }

        let (cell, used) = stores.entry(settings.clone()).or_default();
        *used = *uses;
        cell.clone()
    };

    cell.get_or_init(|| Arc::new(build(settings))).clone()
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
