use std::fmt::Display;
use std::fs::{File, Metadata, OpenOptions, Permissions};
use std::io::{ErrorKind, Read, Seek as _, SeekFrom, Write as _, copy};
use std::os::unix::ffi::OsStrExt as _;
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Component, Path};
use std::time::Instant;

use fs_err as fs;
use nix::unistd::{Gid, Uid, chown, fchown};
use serde::Serialize;
use sha2::{Digest as _, Sha256};
use tempfile::{Builder, NamedTempFile};

use crate::errors::{CliError, CliErrorKind};

use super::model::FileMetadata;

#[path = "files/non_clobber.rs"]
mod non_clobber;
#[cfg(test)]
#[path = "files/tests.rs"]
mod tests;
#[path = "files/trusted_directory.rs"]
mod trusted_directory;

pub(super) use non_clobber::{
    existing_contents, validate_bytes_absent_or_exact, write_bytes_atomic_if_absent_or_exact,
};
pub(super) use trusted_directory::{create_private_directory, validate_private_directory};

pub(super) fn snapshot_optional_file(
    source: &Path,
    destination: &Path,
) -> Result<Option<FileMetadata>, CliError> {
    match fs::symlink_metadata(source) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.is_file() {
                return Err(io_error(format!(
                    "refusing non-regular systemd file {}",
                    source.display()
                )));
            }
            let metadata = metadata_to_file_metadata(&metadata);
            copy_file_atomic(source, destination, metadata)?;
            Ok(Some(metadata))
        }
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(io_error(format!(
            "inspect systemd file {}: {error}",
            source.display()
        ))),
    }
}

pub(super) fn restore_optional_file(
    source: &Path,
    destination: &Path,
    metadata: Option<FileMetadata>,
) -> Result<(), CliError> {
    if let Some(metadata) = metadata {
        copy_file_atomic(source, destination, metadata)
    } else {
        remove_file_if_exists(destination)
    }
}

pub(super) fn copy_file_atomic(
    source: &Path,
    destination: &Path,
    metadata: FileMetadata,
) -> Result<(), CliError> {
    regular_file_metadata(source)?;
    let mut source_file = open_regular_nofollow(source)?;
    copy_open_file_atomic(&mut source_file, source, destination, metadata)
}

pub(super) fn copy_recovery_controller_atomic(
    source: &Path,
    destination: &Path,
    metadata: FileMetadata,
) -> Result<(), CliError> {
    let mut source_file = open_recovery_controller(source)?;
    let expected_sha256 = sha256_reader(&mut source_file, source)?;
    source_file
        .seek(SeekFrom::Start(0))
        .map_err(|error| io_error(format!("rewind recovery controller: {error}")))?;
    copy_open_file_atomic(&mut source_file, source, destination, metadata)?;
    let observed_sha256 = sha256_file(destination)?;
    if observed_sha256 == expected_sha256 {
        Ok(())
    } else {
        Err(io_error(format!(
            "persisted recovery controller digest mismatch: expected {expected_sha256}, found {observed_sha256}"
        )))
    }
}

pub(super) fn recovery_controller_sha256(source: &Path) -> Result<String, CliError> {
    sha256_reader(open_recovery_controller(source)?, source)
}

fn open_recovery_controller(source: &Path) -> Result<File, CliError> {
    let source_file = if source == Path::new("/proc/self/exe") {
        File::open(source).map_err(|error| {
            io_error(format!(
                "open running recovery controller {}: {error}",
                source.display()
            ))
        })?
    } else {
        open_regular_nofollow(source)?
    };
    if source_file
        .metadata()
        .map_err(|error| io_error(format!("inspect running recovery controller: {error}")))?
        .is_file()
    {
        Ok(source_file)
    } else {
        Err(io_error(
            "running recovery controller is not a regular file",
        ))
    }
}

fn copy_open_file_atomic(
    source_file: &mut File,
    source: &Path,
    destination: &Path,
    metadata: FileMetadata,
) -> Result<(), CliError> {
    let parent = destination.parent().ok_or_else(|| {
        io_error(format!(
            "destination has no parent: {}",
            destination.display()
        ))
    })?;
    fs::create_dir_all(parent)
        .map_err(|error| io_error(format!("create directory {}: {error}", parent.display())))?;
    let mut temporary = create_atomic_temporary(parent, destination)?;
    copy(source_file, &mut temporary).map_err(|error| {
        io_error(format!(
            "copy {} to {}: {error}",
            source.display(),
            destination.display()
        ))
    })?;
    temporary
        .as_file_mut()
        .flush()
        .map_err(|error| io_error(format!("flush {}: {error}", destination.display())))?;
    apply_file_metadata(temporary.as_file(), metadata)?;
    temporary
        .as_file()
        .sync_all()
        .map_err(|error| io_error(format!("sync {}: {error}", destination.display())))?;
    temporary.persist(destination).map_err(|error| {
        io_error(format!(
            "persist {}: {}",
            destination.display(),
            error.error
        ))
    })?;
    sync_directory(parent)
}

pub(super) fn open_regular_nofollow(path: &Path) -> Result<File, CliError> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|error| io_error(format!("open regular file {}: {error}", path.display())))?;
    if !file
        .metadata()
        .map_err(|error| io_error(format!("inspect open file {}: {error}", path.display())))?
        .is_file()
    {
        return Err(io_error(format!(
            "{} is not a regular file",
            path.display()
        )));
    }
    Ok(file)
}

pub(super) fn regular_file_metadata(path: &Path) -> Result<Metadata, CliError> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| io_error(format!("inspect regular file {}: {error}", path.display())))?;
    if metadata.file_type().is_symlink() {
        return Err(io_error(format!(
            "refusing symbolic link {}",
            path.display()
        )));
    }
    if !metadata.is_file() {
        return Err(io_error(format!(
            "{} is not a regular file",
            path.display()
        )));
    }
    Ok(metadata)
}

pub(super) fn metadata_to_file_metadata(metadata: &Metadata) -> FileMetadata {
    FileMetadata {
        mode: metadata.mode(),
        uid: metadata.uid(),
        gid: metadata.gid(),
    }
}

fn apply_file_metadata(file: &File, metadata: FileMetadata) -> Result<(), CliError> {
    fchown(
        file,
        Some(Uid::from_raw(metadata.uid)),
        Some(Gid::from_raw(metadata.gid)),
    )
    .map_err(|error| io_error(format!("set file ownership: {error}")))?;
    file.set_permissions(Permissions::from_mode(metadata.mode & 0o7777))
        .map_err(|error| io_error(format!("set file permissions: {error}")))
}

pub(super) fn apply_path_metadata(path: &Path, metadata: FileMetadata) -> Result<(), CliError> {
    chown(
        path,
        Some(Uid::from_raw(metadata.uid)),
        Some(Gid::from_raw(metadata.gid)),
    )
    .map_err(|error| io_error(format!("set ownership {}: {error}", path.display())))?;
    fs::set_permissions(path, Permissions::from_mode(metadata.mode & 0o7777))
        .map_err(|error| io_error(format!("set permissions {}: {error}", path.display())))
}

pub(super) fn write_json_atomic(path: &Path, value: &impl Serialize) -> Result<(), CliError> {
    let mut bytes = serde_json::to_vec_pretty(value)
        .map_err(|error| io_error(format!("encode systemd transaction manifest: {error}")))?;
    bytes.push(b'\n');
    write_bytes_atomic(
        path,
        &bytes,
        FileMetadata::private_executable().with_mode(0o600),
    )
}

pub(super) fn write_bytes_atomic(
    path: &Path,
    bytes: &[u8],
    metadata: FileMetadata,
) -> Result<(), CliError> {
    let parent = path
        .parent()
        .ok_or_else(|| io_error(format!("path has no parent: {}", path.display())))?;
    fs::create_dir_all(parent)
        .map_err(|error| io_error(format!("create directory {}: {error}", parent.display())))?;
    let mut temporary = create_atomic_temporary(parent, path)?;
    temporary
        .write_all(bytes)
        .map_err(|error| io_error(format!("write {}: {error}", path.display())))?;
    temporary
        .flush()
        .map_err(|error| io_error(format!("flush {}: {error}", path.display())))?;
    apply_file_metadata(temporary.as_file(), metadata)?;
    temporary
        .as_file()
        .sync_all()
        .map_err(|error| io_error(format!("sync {}: {error}", path.display())))?;
    temporary
        .persist(path)
        .map_err(|error| io_error(format!("persist {}: {}", path.display(), error.error)))?;
    sync_directory(parent)
}

pub(super) fn validate_candidate(path: &Path) -> Result<(), CliError> {
    validate_absolute_path("candidate binary", path)?;
    let metadata = regular_file_metadata(path)?;
    if metadata.mode() & 0o111 == 0 {
        return Err(io_error(format!(
            "candidate binary is not executable: {}",
            path.display()
        )));
    }
    Ok(())
}

pub(super) fn validate_absolute_path(label: &str, path: &Path) -> Result<(), CliError> {
    if path.is_absolute()
        && !path
            .components()
            .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
    {
        Ok(())
    } else {
        Err(CliErrorKind::workflow_parse(format!(
            "{label} path must be absolute and normalized: {}",
            path.display()
        ))
        .into())
    }
}

pub(super) fn sha256_file(path: &Path) -> Result<String, CliError> {
    sha256_reader(open_regular_nofollow(path)?, path)
}

fn sha256_reader(mut file: impl Read, path: &Path) -> Result<String, CliError> {
    let digest = sha256_reader_until(&mut file, path, None)?;
    digest.ok_or_else(|| io_error("unbounded file digest reached an unexpected deadline"))
}

fn sha256_reader_until(
    mut file: impl Read,
    path: &Path,
    deadline: Option<Instant>,
) -> Result<Option<String>, CliError> {
    let mut digest = Sha256::new();
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            return Ok(None);
        }
        let read = file
            .read(&mut buffer)
            .map_err(|error| io_error(format!("hash {}: {error}", path.display())))?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(Some(hex::encode(digest.finalize())))
}

pub(super) fn running_binary_sha256(
    pid: u32,
    deadline: Option<Instant>,
) -> Result<Option<String>, CliError> {
    if pid == 0 {
        return Err(io_error("systemd MainPID is zero"));
    }
    let path = Path::new("/proc").join(pid.to_string()).join("exe");
    let file = File::open(&path)
        .map_err(|error| io_error(format!("open running binary {}: {error}", path.display())))?;
    sha256_reader_until(file, &path, deadline)
}

pub(super) fn remove_file_if_exists(path: &Path) -> Result<(), CliError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(io_error(format!("remove {}: {error}", path.display()))),
    }
}

pub(super) fn reconcile_atomic_copy_debris(destination: &Path) -> Result<(), CliError> {
    let parent = destination.parent().ok_or_else(|| {
        io_error(format!(
            "atomic copy destination has no parent: {}",
            destination.display()
        ))
    })?;
    let prefix = atomic_copy_temp_prefix(destination);
    let mut changed = false;
    for entry in fs::read_dir(parent).map_err(|error| {
        io_error(format!(
            "read atomic copy parent {}: {error}",
            parent.display()
        ))
    })? {
        let entry = entry.map_err(|error| io_error(format!("read atomic copy debris: {error}")))?;
        if !entry.file_name().as_bytes().starts_with(prefix.as_bytes()) {
            continue;
        }
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path).map_err(|error| {
            io_error(format!(
                "inspect atomic copy debris {}: {error}",
                path.display()
            ))
        })?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(io_error(format!(
                "atomic copy debris is not a regular file: {}",
                path.display()
            )));
        }
        fs::remove_file(&path).map_err(|error| {
            io_error(format!(
                "remove atomic copy debris {}: {error}",
                path.display()
            ))
        })?;
        changed = true;
    }
    if changed {
        sync_directory(parent)?;
    }
    Ok(())
}

fn create_atomic_temporary(parent: &Path, destination: &Path) -> Result<NamedTempFile, CliError> {
    reconcile_atomic_copy_debris(destination)?;
    Builder::new()
        .prefix(&atomic_copy_temp_prefix(destination))
        .tempfile_in(parent)
        .map_err(|error| {
            io_error(format!(
                "create temporary file for {}: {error}",
                destination.display()
            ))
        })
}

fn atomic_copy_temp_prefix(destination: &Path) -> String {
    let digest = Sha256::digest(destination.as_os_str().as_bytes());
    format!(".harness-atomic-{}-", hex::encode(digest))
}

#[cfg(test)]
pub(crate) fn atomic_copy_temp_prefix_for_tests(destination: &Path) -> String {
    atomic_copy_temp_prefix(destination)
}

pub(super) fn remove_tree_if_exists(path: &Path) -> Result<(), CliError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(io_error(format!(
            "refusing symbolic link tree {}",
            path.display()
        ))),
        Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(path)
            .map_err(|error| io_error(format!("remove directory {}: {error}", path.display()))),
        Ok(_) => Err(io_error(format!("{} is not a directory", path.display()))),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(io_error(format!(
            "inspect directory {}: {error}",
            path.display()
        ))),
    }
}

pub(super) fn sync_file(path: &Path) -> Result<(), CliError> {
    File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(|error| io_error(format!("sync file {}: {error}", path.display())))
}

pub(super) fn sync_parent(path: &Path) -> Result<(), CliError> {
    path.parent().map_or(Ok(()), sync_directory)
}

pub(super) fn sync_directory(path: &Path) -> Result<(), CliError> {
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| io_error(format!("sync directory {}: {error}", path.display())))
}

pub(super) fn sqlite_error(operation: &str, path: &Path, error: &dyn Display) -> CliError {
    io_error(format!("{operation} {}: {error}", path.display()))
}

pub(super) fn io_error(message: impl Into<String>) -> CliError {
    CliErrorKind::workflow_io(message.into()).into()
}

pub(super) fn combine_errors(
    operation: &str,
    primary: &CliError,
    recovery: Option<CliError>,
) -> CliError {
    recovery.map_or_else(
        || io_error(format!("{operation}: {primary}")),
        |recovery| {
            io_error(format!(
                "{operation}: {primary}; recovery failed: {recovery}"
            ))
        },
    )
}

pub(super) fn combine_results(
    operation: &str,
    primary: Result<(), CliError>,
    follow_up: Result<(), CliError>,
) -> Result<(), CliError> {
    match primary {
        Ok(()) => follow_up,
        Err(primary) => Err(combine_errors(operation, &primary, follow_up.err())),
    }
}
