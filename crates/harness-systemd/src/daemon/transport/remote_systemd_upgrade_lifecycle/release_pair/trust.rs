use std::env::temp_dir;
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};

use fs_err as fs;

use crate::errors::CliError;

use super::super::files::{io_error, regular_file_metadata};

pub(super) fn validate_trusted_executable(label: &str, path: &Path) -> Result<PathBuf, CliError> {
    let path = canonical_path(label, path)?;
    let metadata = regular_file_metadata(&path)?;
    if metadata.uid() != trusted_uid() {
        return Err(io_error(format!(
            "{label} executable must be owned by uid {}: {}",
            trusted_uid(),
            path.display()
        )));
    }
    if metadata.permissions().mode() & 0o022 != 0 {
        return Err(io_error(format!(
            "{label} executable must not be group or world writable: {}",
            path.display()
        )));
    }
    if metadata.permissions().mode() & 0o111 == 0 {
        return Err(io_error(format!(
            "{label} executable is not executable: {}",
            path.display()
        )));
    }
    validate_trusted_ancestors(label, &path)?;
    Ok(path)
}

pub(super) fn canonical_path(label: &str, path: &Path) -> Result<PathBuf, CliError> {
    path.canonicalize().map_err(|error| {
        io_error(format!(
            "resolve canonical {label} executable {}: {error}",
            path.display()
        ))
    })
}

fn validate_trusted_ancestors(label: &str, path: &Path) -> Result<(), CliError> {
    for ancestor in path.parent().into_iter().flat_map(Path::ancestors) {
        let metadata = fs::symlink_metadata(ancestor).map_err(|error| {
            io_error(format!(
                "inspect {label} executable ancestor {}: {error}",
                ancestor.display()
            ))
        })?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(io_error(format!(
                "{label} executable ancestor is not a real directory: {}",
                ancestor.display()
            )));
        }
        let trusted_owner = metadata.uid() == trusted_uid() || metadata.uid() == 0;
        if !trusted_owner {
            return Err(io_error(format!(
                "{label} executable ancestor has untrusted owner {}: {}",
                metadata.uid(),
                ancestor.display()
            )));
        }
        let sticky_root = metadata.uid() == 0 && metadata.mode() & 0o1000 != 0;
        if metadata.mode() & 0o022 != 0 && !sticky_root {
            return Err(io_error(format!(
                "{label} executable ancestor is group or world writable: {}",
                ancestor.display()
            )));
        }
        if cfg!(test) && ancestor == temp_dir() {
            break;
        }
    }
    Ok(())
}

#[cfg(not(test))]
pub(super) const fn trusted_uid() -> u32 {
    0
}

#[cfg(test)]
pub(super) fn trusted_uid() -> u32 {
    uzers::get_current_uid()
}
