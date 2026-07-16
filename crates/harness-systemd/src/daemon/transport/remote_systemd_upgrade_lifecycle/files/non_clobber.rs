use std::io::{ErrorKind, Read as _, Write as _};
use std::os::unix::fs::MetadataExt as _;
use std::path::Path;

use fs_err as fs;

use crate::errors::CliError;

use super::super::model::FileMetadata;
use super::{
    apply_file_metadata, create_atomic_temporary, io_error, open_regular_nofollow, sync_directory,
};

pub(in super::super) fn write_bytes_atomic_if_absent_or_exact(
    path: &Path,
    bytes: &[u8],
    metadata: FileMetadata,
) -> Result<(), CliError> {
    match existing_contents(path)? {
        Some(contents) if contents == bytes => return Ok(()),
        Some(_) => return Err(unrelated_file_error(path)),
        None => {}
    }
    let parent = path
        .parent()
        .ok_or_else(|| io_error(format!("path has no parent: {}", path.display())))?;
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
    match temporary.persist_noclobber(path) {
        Ok(_) => sync_directory(parent),
        Err(error) if error.error.kind() == ErrorKind::AlreadyExists => {
            if existing_contents(path)?.as_deref() == Some(bytes) {
                Ok(())
            } else {
                Err(unrelated_file_error(path))
            }
        }
        Err(error) => Err(io_error(format!(
            "persist new managed file {}: {}",
            path.display(),
            error.error
        ))),
    }
}

pub(in super::super) fn validate_bytes_absent_or_exact(
    path: &Path,
    bytes: &[u8],
) -> Result<(), CliError> {
    match existing_contents(path)? {
        Some(contents) if contents == bytes => Ok(()),
        Some(_) => Err(unrelated_file_error(path)),
        None => Ok(()),
    }
}

pub(in super::super) fn existing_contents(path: &Path) -> Result<Option<Vec<u8>>, CliError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            Err(unrelated_file_error(path))
        }
        Ok(_) => {
            let mut file = open_regular_nofollow(path)?;
            let metadata = file.metadata().map_err(|error| {
                io_error(format!("inspect managed file {}: {error}", path.display()))
            })?;
            if metadata.uid() != trusted_uid() || metadata.mode() & 0o022 != 0 {
                return Err(io_error(format!(
                    "managed file must be trusted-owner and not group or world writable: {}",
                    path.display()
                )));
            }
            let mut contents = Vec::new();
            file.read_to_end(&mut contents).map_err(|error| {
                io_error(format!("read managed file {}: {error}", path.display()))
            })?;
            Ok(Some(contents))
        }
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(io_error(format!(
            "inspect managed file {}: {error}",
            path.display()
        ))),
    }
}

#[cfg(not(test))]
const fn trusted_uid() -> u32 {
    0
}

#[cfg(test)]
fn trusted_uid() -> u32 {
    uzers::get_current_uid()
}

fn unrelated_file_error(path: &Path) -> CliError {
    io_error(format!(
        "refusing to replace unrelated existing managed file {}",
        path.display()
    ))
}
