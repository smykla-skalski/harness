use std::env::temp_dir;
use std::fs::Metadata;
use std::os::unix::fs::MetadataExt as _;
use std::path::Path;

use fs_err as fs;

use crate::errors::CliError;

use super::super::files::io_error;
use super::trusted_owner;

pub(super) fn validate_trusted_ancestors(path: &Path, label: &str) -> Result<(), CliError> {
    for ancestor in path.parent().into_iter().flat_map(Path::ancestors) {
        let metadata = fs::symlink_metadata(ancestor).map_err(|error| {
            io_error(format!(
                "inspect managed {label} ancestor {}: {error}",
                ancestor.display()
            ))
        })?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(io_error(format!(
                "managed {label} ancestor must be a real directory: {}",
                ancestor.display()
            )));
        }
        if metadata.uid() != 0 && metadata.uid() != trusted_owner().0 {
            return Err(io_error(format!(
                "managed {label} ancestor {} has untrusted owner {}",
                ancestor.display(),
                metadata.uid()
            )));
        }
        if is_test_temp_boundary(ancestor, &metadata) {
            break;
        }
        let writable = metadata.mode() & 0o022 != 0;
        if writable {
            return Err(io_error(format!(
                "managed {label} ancestor {} must not be group- or world-writable (mode {:04o})",
                ancestor.display(),
                metadata.mode() & 0o7777
            )));
        }
    }
    Ok(())
}

fn is_test_temp_boundary(path: &Path, metadata: &Metadata) -> bool {
    if !cfg!(test) {
        return false;
    }
    let secure_session_temp =
        path == temp_dir() && metadata.uid() == trusted_owner().0 && metadata.mode() & 0o022 == 0;
    let sticky_system_temp =
        path == Path::new("/tmp") && metadata.uid() == 0 && metadata.mode() & 0o1000 != 0;
    secure_session_temp || sticky_system_temp
}
