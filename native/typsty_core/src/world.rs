//! The environment a document is compiled in: its source, assigns, files and fonts.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard, PoisonError};

use typst::diag::{FileError, FileResult, PackageError};
use typst::foundations::{Bytes, Datetime, Dict, Duration, Value};
use typst::syntax::{FileId, Lines, PathError, RootedPath, Source, VirtualPath, VirtualRoot};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World};
use typst_kit::files::FsRoot;
use typst_kit::fonts::FontStore;
use typst_kit::packages::FsPackages;

use crate::checks;
use crate::isolate::{self, Cancellation};

/// The path of the main source file in the project.
pub const MAIN_PATH: &str = "/main.typ";

/// The id of the main source file.
pub static MAIN_ID: LazyLock<FileId> = LazyLock::new(|| {
    FileId::new(RootedPath::new(
        VirtualRoot::Project,
        VirtualPath::new(MAIN_PATH).unwrap(),
    ))
});

// Typst gives every file path an id that lasts for the life of the VM, and it can only make
// 65,535 of them: after that, it panics while holding the lock on its table of paths, and
// every later render fails until the VM restarts. Typsty keeps well away from that:
//
// - a render may use at most `MAX_RENDER_FILES` paths, so one document can't use them up
// - once the ids reach `MAX_FILE_ID`, renders that need a new path are stopped
// - the paths given in `:files` are capped at `MAX_GIVEN_PATHS`, leaving room for the files
//   Typst reads itself (imports, packages and files read from disk)
//
// Typst creates the id of a path just before it asks the world for the file, so the world
// sees every new id as it's created.

/// The most distinct file paths one render may use.
pub const MAX_RENDER_FILES: usize = 10_000;

/// The highest file id renders may use. Typst's last one is 65,535; the rest is room for the
/// ids that renders running at the same time create before they're stopped.
pub const MAX_FILE_ID: u16 = 64_000;

/// The most distinct paths that may be given in `:files`, over the life of the VM.
pub const MAX_GIVEN_PATHS: usize = 50_000;

/// The highest file id seen.
static HIGHEST_FILE_ID: AtomicU16 = AtomicU16::new(0);

static GIVEN_PATHS: LazyLock<Mutex<HashSet<String>>> = LazyLock::new(|| Mutex::new(HashSet::new()));

/// The standard library for documents without assigns, whose `sys.inputs.assigns` is an empty
/// dictionary, so that imported files can read it whether there are assigns or not.
static LIBRARY: LazyLock<LazyHash<Library>> = LazyLock::new(|| LazyHash::new(library(Dict::new())));

/// The standard library, with the assigns in `sys.inputs.assigns`.
fn library(assigns: Dict) -> Library {
    let mut inputs = Dict::new();
    inputs.insert("assigns".into(), Value::Dict(assigns));
    Library::builder().with_inputs(inputs).build()
}

/// The line added before the template, which binds its assigns. The assigns are passed in
/// `sys.inputs.assigns` (rather than as `sys.inputs` itself, which packages read their own
/// settings from), and bound to the `assigns` variable at the top of the main file. Like a
/// `let` binding in the template itself, it's only visible in the main file: imported files
/// and packages don't see it (they can read `sys.inputs.assigns`).
const PREAMBLE: &str = "#let assigns = sys.inputs.at(\"assigns\", default: (:))\n";

/// Files read from the root directory or from package directories may be at most this
/// large: 512 MiB.
pub const MAX_FILE_SIZE: u64 = 512 * 1024 * 1024;

/// Why a render's arguments were refused before it started.
pub enum PrepareError {
    /// They're invalid, which is raised as an `ArgumentError`.
    Invalid(String),
    /// They're valid, but go over one of Typsty's limits, which is reported like Typst's
    /// errors.
    Refused(String),
}

/// What a document reads, checked before its render starts (see `Prepared::new`).
pub struct Prepared {
    library: Option<LazyHash<Library>>,
    /// The template, which is only parsed on the render's thread: parsing recurses, and the
    /// thread preparing the render is one of the BEAM's, with a small stack.
    template: String,
    files: HashMap<FileId, Bytes>,
    root: Option<FsRoot>,
    packages: Vec<FsPackages>,
}

impl Prepared {
    /// Checks the file paths, which is quick: fonts and files are only read when the
    /// document renders.
    pub fn new(
        template: String,
        assigns: Dict,
        files: Vec<(String, Vec<u8>)>,
        root: Option<String>,
        package_paths: Vec<String>,
    ) -> Result<Self, PrepareError> {
        let library = (!assigns.is_empty()).then(|| LazyHash::new(library(assigns)));

        let mut given = HashMap::with_capacity(files.len());
        for (path, bytes) in files {
            let id = given_file(&path)?;

            if id == *MAIN_ID {
                return Err(PrepareError::Invalid(format!(
                    "the file path {path:?} in the :files option is reserved for the template itself"
                )));
            }

            if given.insert(id, Bytes::new(bytes)).is_some() {
                return Err(PrepareError::Invalid(format!(
                    "the :files option has the path {path:?} more than once (paths are relative to the project root, so \"logo.png\" and \"/logo.png\" are the same file)"
                )));
            }
        }

        // Files are confined to the root even through symbolic links, which is checked
        // against the root's real path
        let root = match root {
            Some(root) => match std::fs::canonicalize(&root) {
                Ok(real) if real.is_dir() => Some(FsRoot::new(real)),
                _ => {
                    return Err(PrepareError::Invalid(format!(
                        "the :root directory {root:?} doesn't exist, or isn't a directory (in a release, find directories in priv with Application.app_dir/2)"
                    )))
                }
            },
            None => None,
        };

        let template = match template.strip_prefix('\u{feff}') {
            Some(stripped) => stripped.to_string(),
            None => template,
        };

        Ok(Self {
            library,
            template,
            files: given,
            root,
            packages: package_paths.into_iter().map(FsPackages::new).collect(),
        })
    }
}

pub struct TypstyWorld {
    library: Option<LazyHash<Library>>,
    fonts: Arc<FontStore>,
    main: Source,
    /// The template, without the preamble, for reading the main file as data.
    template: Bytes,
    /// The files given to the render, which take precedence over the root directory.
    files: HashMap<FileId, Bytes>,
    root: Option<FsRoot>,
    packages: Vec<FsPackages>,
    /// Files read from the root directory or from packages, before they're checked.
    loaded: Mutex<HashMap<FileId, FileResult<Bytes>>>,
    /// Files that were checked (see `checks`): only files the document reads as data are, not
    /// the sources it imports.
    checked: Mutex<HashMap<FileId, FileResult<()>>>,
    sources: Mutex<HashMap<FileId, Source>>,
    /// The file ids the render used, to limit how many paths it may use.
    used: Mutex<HashSet<FileId>>,
    now: time::OffsetDateTime,
    cancellation: Cancellation,
}

impl TypstyWorld {
    pub fn new(prepared: Prepared, fonts: Arc<FontStore>, cancellation: Cancellation) -> Self {
        let main = Source::new(*MAIN_ID, format!("{PREAMBLE}{}", prepared.template));

        Self {
            library: prepared.library,
            fonts,
            main,
            template: Bytes::from_string(prepared.template),
            files: prepared.files,
            root: prepared.root,
            packages: prepared.packages,
            loaded: Mutex::new(HashMap::new()),
            checked: Mutex::new(HashMap::new()),
            sources: Mutex::new(HashMap::new()),
            used: Mutex::new(HashSet::new()),
            now: time::OffsetDateTime::now_utc(),
            cancellation,
        }
    }

    /// Unwinds the render if it was cancelled (see `isolate`).
    pub fn check_cancelled(&self) {
        self.cancellation.check();
    }

    pub fn main_source(&self) -> &Source {
        &self.main
    }

    /// The number of lines added before the template (see `PREAMBLE`).
    pub fn preamble_lines(&self) -> usize {
        PREAMBLE.lines().count()
    }

    /// The time the document is rendered at, in UTC.
    pub fn now(&self) -> Datetime {
        Datetime::Datetime(time::PrimitiveDateTime::new(
            self.now.date(),
            self.now.time(),
        ))
    }

    /// Stops the render if the file's id is past `MAX_FILE_ID`, or if the render has used
    /// more than `MAX_RENDER_FILES` paths. Called at the start of `World` methods, while the
    /// world holds none of its locks (see `isolate::stop`).
    fn track(&self, id: FileId) {
        if id == self.main.id() {
            return;
        }

        if observe(id) > MAX_FILE_ID {
            isolate::stop(format!(
                "the document needs a new file path, but {TABLE_FULL}"
            ));
        }

        let used = {
            let mut used = lock(&self.used);
            used.insert(id);
            used.len()
        };

        if used > MAX_RENDER_FILES {
            isolate::stop(format!(
                "the document reads more than {MAX_RENDER_FILES} different files. Typst keeps every file path it sees, for as long as the VM (or a Typsty.Pool worker) runs, so a render may only use {MAX_RENDER_FILES} of them"
            ));
        }
    }

    /// The lines of a file, to turn a position in it into a line and column: a parsed
    /// source's, or the file's text, which isn't parsed as Typst just for that (it may be a
    /// large data file).
    pub fn lines(&self, id: FileId) -> Option<Lines<String>> {
        if let Some(source) = lock(&self.sources).get(&id) {
            return Some(source.lines().clone());
        }

        let bytes = self.raw(id).ok()?;
        let text = std::str::from_utf8(&bytes).ok()?;
        Some(Lines::new(text.to_string()))
    }

    /// A file's contents, before they're checked.
    fn raw(&self, id: FileId) -> FileResult<Bytes> {
        if id == self.main.id() {
            return Ok(self.template.clone());
        }

        if let Some(bytes) = self.files.get(&id) {
            return Ok(bytes.clone());
        }

        if let Some(result) = lock(&self.loaded).get(&id) {
            return result.clone();
        }

        // Not locked while reading, so that other threads of the render can read other files.
        // Two threads may read the same file at once, which is only wasted work
        let result = self.load(id);
        lock(&self.loaded).insert(id, result.clone());
        result
    }

    /// Reads a file that wasn't given to the render: from the root directory, or from a
    /// package directory.
    fn load(&self, id: FileId) -> FileResult<Bytes> {
        let (root, outside) = match id.root() {
            // The directory is reserved for the components given to the render, which are in
            // `files`
            VirtualRoot::Project if is_component_path(id.vpath().get_with_slash()) => {
                return Err(not_a_component(id));
            }
            VirtualRoot::Project => {
                let root = self.root.as_ref().ok_or_else(|| {
                    FileError::Other(Some(
                        format!(
                            "{} is not in the :files option, and there is no :root directory to read it from",
                            id.vpath().get_with_slash()
                        )
                        .into(),
                    ))
                })?;
                (root.clone(), "the :root directory")
            }
            VirtualRoot::Package(spec) => {
                let root = self
                    .packages
                    .iter()
                    .find_map(|packages| packages.obtain(spec))
                    .ok_or_else(|| FileError::Package(PackageError::NotFound(spec.clone())))?;
                (root, "its package's directory")
            }
        };

        let path = confine(&root.resolve(id.vpath())?, root.path(), || {
            format!(
                "{} is outside {outside}, through a symbolic link",
                id.vpath().get_with_slash()
            )
        })?;

        // What's reserved is the directory on disk: on a file system that ignores case,
        // /Components/x is components/x too, as is a path through a symbolic link to it
        if matches!(id.root(), VirtualRoot::Project) && in_components_dir(&path, root.path()) {
            return Err(not_a_component(id));
        }

        read_regular_file(&path).map(Bytes::new)
    }
}

/// The file's real path, if it's inside the root: symbolic links are followed, so that a
/// link can't lead outside the root.
fn confine(path: &Path, root: &Path, outside: impl FnOnce() -> String) -> FileResult<PathBuf> {
    let real = std::fs::canonicalize(path).map_err(|error| FileError::from_io(error, path))?;
    let real_root = std::fs::canonicalize(root).map_err(|error| FileError::from_io(error, root))?;

    if real.starts_with(&real_root) {
        Ok(real)
    } else {
        Err(FileError::Other(Some(outside().into())))
    }
}

/// Reads a file, refusing anything but regular files of at most `MAX_FILE_SIZE`: reading a
/// device such as /dev/zero never ends, and reading a FIFO can block forever. The file is
/// opened once, and checked through its handle, so that it can't be swapped in between;
/// opening doesn't block on a FIFO.
fn read_regular_file(path: &Path) -> FileResult<Vec<u8>> {
    use std::io::Read;

    let mut options = std::fs::OpenOptions::new();
    options.read(true);

    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }

    let file = options
        .open(path)
        .map_err(|error| FileError::from_io(error, path))?;
    let metadata = file
        .metadata()
        .map_err(|error| FileError::from_io(error, path))?;

    if metadata.is_dir() {
        return Err(FileError::IsDirectory);
    }

    if !metadata.is_file() {
        return Err(FileError::Other(Some(
            format!("{} is not a regular file", path.display()).into(),
        )));
    }

    if metadata.len() > MAX_FILE_SIZE {
        return Err(FileError::Other(Some(
            format!(
                "{} is larger than {} MiB, the most a document may read from disk",
                path.display(),
                MAX_FILE_SIZE / 1024 / 1024
            )
            .into(),
        )));
    }

    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(MAX_FILE_SIZE)
        .read_to_end(&mut bytes)
        .map_err(|error| FileError::from_io(error, path))?;
    Ok(bytes)
}

impl World for TypstyWorld {
    // Every method starts by checking whether the render was cancelled: these are the points
    // where a cancelled render stops.

    fn library(&self) -> &LazyHash<Library> {
        self.check_cancelled();
        self.library.as_ref().unwrap_or(&LIBRARY)
    }

    fn book(&self) -> &LazyHash<FontBook> {
        self.check_cancelled();
        self.fonts.book()
    }

    fn main(&self) -> FileId {
        self.check_cancelled();
        self.main.id()
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        self.check_cancelled();
        self.track(id);

        if id == self.main.id() {
            return Ok(self.main.clone());
        }

        if let Some(source) = lock(&self.sources).get(&id) {
            return Ok(source.clone());
        }

        // Sources aren't checked like files: Typst's parser limits how deeply they nest
        let bytes = self.raw(id)?;
        let text = std::str::from_utf8(&bytes).map_err(|_| FileError::InvalidUtf8)?;
        let source = Source::new(id, strip_bom(text).into());
        lock(&self.sources).insert(id, source.clone());
        Ok(source)
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        self.check_cancelled();
        self.track(id);

        let bytes = self.raw(id)?;
        if id == self.main.id() {
            return Ok(bytes);
        }

        let checked = lock(&self.checked).get(&id).cloned();
        let checked = checked.unwrap_or_else(|| {
            let result = checks::check(&bytes, id.vpath().extension())
                .map_err(|problem| FileError::Other(Some(problem.into())));
            lock(&self.checked).insert(id, result.clone());
            result
        });

        checked.map(|()| bytes)
    }

    fn font(&self, index: usize) -> Option<Font> {
        self.check_cancelled();
        self.fonts.font(index)
    }

    // Without an offset, Typst asks for the local date. The server's time zone is rarely what
    // a document wants, so UTC is used, and templates can ask for an offset explicitly.
    fn today(&self, offset: Option<Duration>) -> Option<Datetime> {
        self.check_cancelled();
        let offset = offset.map(time::Duration::from).unwrap_or_default();
        let now = self.now.checked_add(offset)?;
        Some(Datetime::Date(now.date()))
    }
}

/// Records a file id that Typst created, returning its number.
fn observe(id: FileId) -> u16 {
    let number = id.into_raw().get();
    HIGHEST_FILE_ID.fetch_max(number, Ordering::Relaxed);
    number
}

/// What's wrong when Typst's table of file paths is full.
const TABLE_FULL: &str = "Typst's table of file paths is full: it keeps every file path it sees, for as long as the VM (or a Typsty.Pool worker) runs. Use stable file names, like logo.png, rather than a new name for every render. Inside the VM, the table empties when the VM restarts; a Typsty.Pool replaces a worker whose table is nearly full";

/// Whether Typst's table of file paths is close to full: a process that can be replaced
/// (the worker) should be.
pub fn file_ids_running_out() -> bool {
    HIGHEST_FILE_ID.load(Ordering::Relaxed) as usize >= MAX_FILE_ID as usize - MAX_RENDER_FILES
}

/// Whether close to `MAX_GIVEN_PATHS` paths were given in `:files`: a process that can be
/// replaced (the worker) should be, before it has to refuse new ones.
pub fn given_paths_running_out() -> bool {
    lock(&GIVEN_PATHS).len() >= MAX_GIVEN_PATHS - MAX_RENDER_FILES
}

/// The id of a file given in `:files`. New paths are refused when too many were given, or
/// when Typst's table of paths is nearly full, before Typst creates an id for them.
fn given_file(path: &str) -> Result<FileId, PrepareError> {
    let vpath = VirtualPath::new(path).map_err(|error| {
        let reason = match error {
            PathError::Escapes => "it leads outside the project root",
            PathError::Backslash => "paths use forward slashes (/), not backslashes",
        };
        PrepareError::Invalid(format!(
            "invalid file path in the :files option: {path:?}: {reason}"
        ))
    })?;

    {
        let mut paths = lock(&GIVEN_PATHS);
        if !paths.contains(vpath.get_with_slash()) {
            if paths.len() >= MAX_GIVEN_PATHS {
                return Err(PrepareError::Refused(format!(
                    "the :files option has a new file path, {path:?}, but {MAX_GIVEN_PATHS} different paths were already given. {TABLE_FULL}"
                )));
            }

            if HIGHEST_FILE_ID.load(Ordering::Relaxed) >= MAX_FILE_ID {
                return Err(PrepareError::Refused(format!(
                    "the :files option has a new file path, {path:?}, but {TABLE_FULL}"
                )));
            }

            paths.insert(vpath.get_with_slash().to_string());
        }
    }

    let id = FileId::new(RootedPath::new(VirtualRoot::Project, vpath));
    observe(id);
    Ok(id)
}

/// Whether a path in the project (starting with a slash) is in the `components/` directory,
/// which only has the components given to the render.
fn is_component_path(path: &str) -> bool {
    path.starts_with("/components/")
}

/// Whether a file's real path (see `confine`) is in the root's `components/` directory, as
/// it's named on disk.
fn in_components_dir(real: &Path, root: &Path) -> bool {
    std::fs::canonicalize(root)
        .ok()
        .and_then(|real_root| {
            real.strip_prefix(real_root)
                .ok()?
                .components()
                .next()
                .map(|first| first.as_os_str() == "components")
        })
        .unwrap_or(false)
}

fn not_a_component(id: FileId) -> FileError {
    FileError::Other(Some(
        format!(
            "{} is not one of the render's components, or one of their files (components/ only has the components given to the render, and their files). Add the component's module to `use Typsty, components: [...]`, or to the :components option",
            id.vpath().get_with_slash()
        )
        .into(),
    ))
}

/// Typst's parser doesn't skip a byte order mark, which would become part of the first line.
pub fn strip_bom(text: &str) -> &str {
    text.strip_prefix('\u{feff}').unwrap_or(text)
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
