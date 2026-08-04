use std::fs::OpenOptions;
use std::io::{self, Read, Write as _};
#[cfg(unix)]
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};

use super::{
    BRIDGE_LEGACY_REDIRECT_LOGS, DAEMON_LEGACY_REDIRECT_LOGS, LogFormat, archive_path,
    bounded_marker, open_no_follow, remove_if_exists, rotate_archives,
};

pub(super) struct RetentionState {
    prepared_paths: Vec<PreparedPath>,
}

struct PreparedPath {
    path: PathBuf,
    format: LogFormat,
    identity: Option<FileIdentity>,
}

#[cfg(unix)]
#[derive(Clone, Copy, PartialEq, Eq)]
struct FileIdentity {
    device: u64,
    inode: u64,
}

#[cfg(not(unix))]
#[derive(Clone, Copy, PartialEq, Eq)]
struct FileIdentity;

#[derive(Debug)]
pub(super) struct CleanupWarning {
    pub(super) path: PathBuf,
    pub(super) error: io::Error,
}

impl RetentionState {
    pub(super) const fn new() -> Self {
        Self {
            prepared_paths: Vec::new(),
        }
    }

    pub(super) fn prepare_path(
        &mut self,
        path: &Path,
        max_file_bytes: u64,
        archive_count: usize,
        format: LogFormat,
    ) -> io::Result<Vec<CleanupWarning>> {
        let current_identity = reset_unsafe_current(path)?;
        let prepared = self
            .prepared_paths
            .iter()
            .find(|prepared| prepared.path == path);
        if current_identity.is_some()
            && prepared.is_some_and(|prepared| {
                prepared.format == format && prepared.identity == current_identity
            })
        {
            return Ok(Vec::new());
        }
        let first_preparation = prepared.is_none();
        let cleanup_warnings = if first_preparation {
            let warnings = prepare_legacy_redirects(path);
            prune_extra_archives(path, archive_count)?;
            bound_existing_archives(path, max_file_bytes, archive_count, format)?;
            warnings
        } else {
            Vec::new()
        };
        if file_format(path)?.is_some_and(|existing| existing != format) {
            rotate_archives(path, max_file_bytes, archive_count, format)?;
        }
        self.remember_current(path, format)?;
        Ok(cleanup_warnings)
    }

    pub(super) fn remember_current(&mut self, path: &Path, format: LogFormat) -> io::Result<()> {
        let identity = reset_unsafe_current(path)?;
        self.prepared_paths.retain(|prepared| prepared.path != path);
        self.prepared_paths.push(PreparedPath {
            path: path.to_path_buf(),
            format,
            identity,
        });
        Ok(())
    }
}

fn prepare_legacy_redirects(path: &Path) -> Vec<CleanupWarning> {
    let Some(parent) = path.parent() else {
        return Vec::new();
    };
    let names: &[&str] = match path.file_name().and_then(std::ffi::OsStr::to_str) {
        Some("daemon.log") => &DAEMON_LEGACY_REDIRECT_LOGS,
        Some("bridge.log") => &BRIDGE_LEGACY_REDIRECT_LOGS,
        _ => &[],
    };
    let mut warnings = Vec::new();
    for name in names {
        let legacy_path = parent.join(name);
        if let Err(error) = reset_legacy_redirect(&legacy_path) {
            warnings.push(CleanupWarning {
                path: legacy_path,
                error,
            });
        }
    }
    warnings
}

fn reset_legacy_redirect(path: &Path) -> io::Result<()> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() || has_multiple_links(&metadata) {
        return remove_if_exists(path);
    }
    let mut options = OpenOptions::new();
    options.write(true);
    let file = open_no_follow(&mut options, path)?;
    let opened = file.metadata()?;
    if !opened.is_file() || has_multiple_links(&opened) || !same_file_identity(&metadata, &opened) {
        return Err(io::Error::other(
            "legacy log path changed before it could be truncated safely",
        ));
    }
    file.set_len(0)
}

fn reset_unsafe_current(path: &Path) -> io::Result<Option<FileIdentity>> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() || has_multiple_links(&metadata) {
        remove_if_exists(path)?;
        return Ok(None);
    }
    #[cfg(unix)]
    {
        Ok(Some(file_identity(&metadata)))
    }
    #[cfg(not(unix))]
    {
        Ok(None)
    }
}

#[cfg(unix)]
pub(super) fn has_multiple_links(metadata: &std::fs::Metadata) -> bool {
    metadata.nlink() > 1
}

#[cfg(not(unix))]
pub(super) fn has_multiple_links(_metadata: &std::fs::Metadata) -> bool {
    false
}

#[cfg(unix)]
fn file_identity(metadata: &std::fs::Metadata) -> FileIdentity {
    FileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    }
}

#[cfg(unix)]
fn same_file_identity(left: &std::fs::Metadata, right: &std::fs::Metadata) -> bool {
    left.dev() == right.dev() && left.ino() == right.ino()
}

#[cfg(not(unix))]
fn same_file_identity(_left: &std::fs::Metadata, _right: &std::fs::Metadata) -> bool {
    true
}

fn prune_extra_archives(path: &Path, archive_count: usize) -> io::Result<()> {
    let Some(parent) = path.parent() else {
        return Ok(());
    };
    let Some(base) = path.file_name().and_then(std::ffi::OsStr::to_str) else {
        return Ok(());
    };
    let prefix = format!("{base}.");
    let entries = match std::fs::read_dir(parent) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    for entry in entries {
        let entry = entry?;
        let name = entry.file_name();
        let Some(suffix) = name.to_str().and_then(|name| name.strip_prefix(&prefix)) else {
            continue;
        };
        if suffix.is_empty() || !suffix.bytes().all(|byte| byte.is_ascii_digit()) {
            continue;
        }
        let should_remove = suffix.parse::<usize>().map_or(true, |generation| {
            generation == 0 || suffix != generation.to_string() || generation > archive_count
        });
        if should_remove {
            let file_type = entry.file_type()?;
            if file_type.is_file() || file_type.is_symlink() {
                remove_if_exists(&entry.path())?;
            }
        }
    }
    Ok(())
}

fn bound_existing_archives(
    path: &Path,
    max_file_bytes: u64,
    archive_count: usize,
    fallback_format: LogFormat,
) -> io::Result<()> {
    for generation in 1..=archive_count {
        let archive = archive_path(path, generation);
        let metadata = match std::fs::symlink_metadata(&archive) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        if metadata.file_type().is_symlink() || has_multiple_links(&metadata) {
            remove_if_exists(&archive)?;
        } else if metadata.is_file() && metadata.len() > max_file_bytes {
            let format = file_format(&archive)?.unwrap_or(fallback_format);
            let marker = bounded_marker(
                format,
                "legacy daemon log archive omitted because it exceeded the file limit",
                metadata.len(),
                max_file_bytes,
            );
            replace_file(&archive, &marker)?;
        }
    }
    Ok(())
}

fn file_format(path: &Path) -> io::Result<Option<LogFormat>> {
    let mut options = OpenOptions::new();
    options.read(true);
    let mut file = match open_no_follow(&mut options, path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let mut prefix = Vec::new();
    Read::by_ref(&mut file)
        .take(4_096)
        .read_to_end(&mut prefix)?;
    Ok(prefix
        .iter()
        .find(|byte| !byte.is_ascii_whitespace())
        .map(|byte| {
            if *byte == b'{' {
                LogFormat::Json
            } else {
                LogFormat::Text
            }
        }))
}

fn replace_file(path: &Path, contents: &[u8]) -> io::Result<()> {
    remove_if_exists(path)?;
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    open_no_follow(&mut options, path)?.write_all(contents)
}
