//! The environment a document is compiled in: its source, variables, files and fonts.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, LazyLock, Mutex};

use typst::diag::{FileError, FileResult, PackageError};
use typst::foundations::{Bytes, Datetime, Dict, Duration};
use typst::syntax::{FileId, RootedPath, Source, VirtualPath, VirtualRoot};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World};
use typst_kit::files::FsRoot;
use typst_kit::fonts::FontStore;
use typst_kit::packages::FsPackages;

use crate::checks;

/// The path of the main source file in the project.
pub const MAIN_PATH: &str = "/main.typ";

/// The id of the main source file.
pub static MAIN_ID: LazyLock<FileId> = LazyLock::new(|| {
    FileId::new(RootedPath::new(
        VirtualRoot::Project,
        VirtualPath::new(MAIN_PATH).unwrap(),
    ))
});

/// Typst gives every file path an id that lasts for the life of the VM, and it can only
/// make 65,535 of them: after that, it panics, and every later compilation fails until the
/// VM restarts. So the paths given in `:files` are capped below that, leaving room for the
/// files Typst reads itself (imports, packages and files read from disk).
const MAX_FILE_PATHS: usize = 50_000;

static FILE_PATHS: LazyLock<Mutex<HashSet<String>>> = LazyLock::new(|| Mutex::new(HashSet::new()));

/// The standard library for documents without variables.
static LIBRARY: LazyLock<LazyHash<Library>> = LazyLock::new(|| LazyHash::new(Library::default()));

/// Words that can't be used as variable names.
const KEYWORDS: &[&str] = &[
    "none", "auto", "true", "false", "not", "and", "or", "let", "set", "show", "context", "if",
    "else", "for", "in", "while", "break", "continue", "return", "import", "include", "as",
];

pub struct TypstyWorld {
    library: Option<LazyHash<Library>>,
    fonts: Arc<FontStore>,
    main: Source,
    /// The number of lines added before the template to bind its variables.
    preamble_lines: usize,
    /// The files given to the render, which take precedence over the root directory. A file
    /// that failed the checks in `checks` holds its error.
    files: HashMap<FileId, FileResult<Bytes>>,
    root: Option<FsRoot>,
    packages: Vec<FsPackages>,
    /// Files read from the root directory or from packages, and parsed sources.
    loaded: Mutex<HashMap<FileId, FileResult<Bytes>>>,
    sources: Mutex<HashMap<FileId, Source>>,
    now: time::OffsetDateTime,
}

pub struct WorldOptions {
    pub files: Vec<(String, Vec<u8>)>,
    pub root: Option<String>,
    pub package_paths: Vec<String>,
    pub fonts: Arc<FontStore>,
}

impl TypstyWorld {
    pub fn new(template: &str, variables: Dict, options: WorldOptions) -> Result<Self, String> {
        // The variables are passed in sys.inputs, and bound as regular variables at the top of
        // the main file. Like `let` bindings in the template itself, they're only visible in
        // the main file: they don't shadow the standard library in imported files and packages
        let (library, preamble, preamble_lines) = if variables.is_empty() {
            (None, String::new(), 0)
        } else {
            let names = variables
                .iter()
                .map(|(name, _)| {
                    if is_variable_name(name) {
                        Ok(name.as_str())
                    } else {
                        Err(format!(
                            "invalid variables: {name:?} is not a valid Typst variable name"
                        ))
                    }
                })
                .collect::<Result<Vec<_>, _>>()?;

            let preamble = format!("#let ({},) = sys.inputs\n", names.join(", "));
            let library = Library::builder().with_inputs(variables).build();
            (Some(LazyHash::new(library)), preamble, 1)
        };

        let mut files = HashMap::with_capacity(options.files.len());
        for (path, bytes) in options.files {
            let id = project_file(&path)?;

            if id == *MAIN_ID {
                return Err(format!(
                    "the file path {path:?} is reserved for the template itself"
                ));
            }

            let checked = checks::check(&bytes)
                .map(|()| Bytes::new(bytes))
                .map_err(|problem| FileError::Other(Some(problem.into())));
            files.insert(id, checked);
        }

        Ok(Self {
            library,
            fonts: options.fonts,
            main: Source::new(*MAIN_ID, preamble + template),
            preamble_lines,
            files,
            root: options.root.map(|root| FsRoot::new(root.into())),
            packages: options
                .package_paths
                .into_iter()
                .map(FsPackages::new)
                .collect(),
            loaded: Mutex::new(HashMap::new()),
            sources: Mutex::new(HashMap::new()),
            now: time::OffsetDateTime::now_utc(),
        })
    }

    pub fn main_source(&self) -> &Source {
        &self.main
    }

    pub fn preamble_lines(&self) -> usize {
        self.preamble_lines
    }

    /// The time the document is rendered at, in UTC.
    pub fn now(&self) -> Datetime {
        Datetime::Datetime(time::PrimitiveDateTime::new(
            self.now.date(),
            self.now.time(),
        ))
    }

    /// Loads a file that wasn't given to the render: from the root directory, or from a
    /// package directory.
    fn load(&self, id: FileId) -> FileResult<Bytes> {
        let mut loaded = self.loaded.lock().map_err(|_| FileError::AccessDenied)?;
        if let Some(result) = loaded.get(&id) {
            return result.clone();
        }

        let result = self.read(id);
        loaded.insert(id, result.clone());
        result
    }

    fn read(&self, id: FileId) -> FileResult<Bytes> {
        let root = match id.root() {
            VirtualRoot::Project => self.root.clone().ok_or_else(|| {
                FileError::Other(Some(
                    format!(
                        "{} is not in the :files option, and there is no :root directory to read it from",
                        id.vpath().get_with_slash()
                    )
                    .into(),
                ))
            })?,
            VirtualRoot::Package(spec) => self
                .packages
                .iter()
                .find_map(|packages| packages.obtain(spec))
                .ok_or_else(|| FileError::Package(PackageError::NotFound(spec.clone())))?,
        };

        let path = root.resolve(id.vpath())?;
        let bytes = read_regular_file(&path)?;
        checks::check(&bytes).map_err(|problem| FileError::Other(Some(problem.into())))?;
        Ok(Bytes::new(bytes))
    }
}

/// Reads a file, refusing anything but regular files (following symlinks): reading a device
/// such as /dev/zero never ends, and reading a FIFO can block forever.
fn read_regular_file(path: &Path) -> FileResult<Vec<u8>> {
    let metadata = std::fs::metadata(path).map_err(|error| FileError::from_io(error, path))?;

    if metadata.is_dir() {
        return Err(FileError::IsDirectory);
    }

    if !metadata.is_file() {
        return Err(FileError::Other(Some(
            format!("{} is not a regular file", path.display()).into(),
        )));
    }

    std::fs::read(path).map_err(|error| FileError::from_io(error, path))
}

impl World for TypstyWorld {
    fn library(&self) -> &LazyHash<Library> {
        self.library.as_ref().unwrap_or(&LIBRARY)
    }

    fn book(&self) -> &LazyHash<FontBook> {
        self.fonts.book()
    }

    fn main(&self) -> FileId {
        self.main.id()
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        if id == self.main.id() {
            return Ok(self.main.clone());
        }

        let mut sources = self.sources.lock().map_err(|_| FileError::AccessDenied)?;
        if let Some(source) = sources.get(&id) {
            return Ok(source.clone());
        }

        let bytes = self.file(id)?;
        let text = std::str::from_utf8(&bytes).map_err(|_| FileError::InvalidUtf8)?;
        let source = Source::new(id, text.trim_start_matches('\u{feff}').into());
        sources.insert(id, source.clone());
        Ok(source)
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        if id == self.main.id() {
            return Ok(Bytes::from_string(self.main.clone()));
        }

        match self.files.get(&id) {
            Some(result) => result.clone(),
            None => self.load(id),
        }
    }

    fn font(&self, index: usize) -> Option<Font> {
        self.fonts.font(index)
    }

    // Without an offset, Typst asks for the local date. The server's time zone is rarely what
    // a document wants, so UTC is used, and templates can ask for an offset explicitly.
    fn today(&self, offset: Option<Duration>) -> Option<Datetime> {
        let offset = offset.map(time::Duration::from).unwrap_or_default();
        let now = self.now.checked_add(offset)?;
        Some(Datetime::Date(now.date()))
    }
}

/// The id of a file given in `:files`, within the cap on file paths.
fn project_file(path: &str) -> Result<FileId, String> {
    let vpath = VirtualPath::new(path).map_err(|_| format!("invalid file path: {path:?}"))?;

    let mut paths = FILE_PATHS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if !paths.contains(vpath.get_with_slash()) {
        if paths.len() >= MAX_FILE_PATHS {
            return Err(format!(
                "too many distinct file paths: Typst keeps every file path for the life of the VM, and this one would be more than {MAX_FILE_PATHS}. Use stable file names, like logo.png, rather than a new name for every render"
            ));
        }

        paths.insert(vpath.get_with_slash().to_string());
    }

    Ok(FileId::new(RootedPath::new(VirtualRoot::Project, vpath)))
}

fn is_variable_name(name: &str) -> bool {
    typst::syntax::is_ident(name) && !KEYWORDS.contains(&name)
}
