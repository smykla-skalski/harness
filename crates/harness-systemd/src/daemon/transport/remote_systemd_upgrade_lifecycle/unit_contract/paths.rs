use std::env::temp_dir;
use std::fs::Metadata;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};

use fs_err as fs;

use crate::errors::CliError;

use super::super::files::io_error;
use super::trusted_owner;

pub(super) fn validate_trusted_ancestors(path: &Path, label: &str) -> Result<(), CliError> {
    let canonical_temp_dir = canonical_test_boundary(&temp_dir());
    let canonical_tmp = canonical_test_boundary(Path::new("/tmp"));
    let canonical_manifest_dir = canonical_test_boundary(Path::new(env!("CARGO_MANIFEST_DIR")));
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
        if is_test_temp_boundary(
            ancestor,
            &metadata,
            canonical_temp_dir.as_deref(),
            canonical_tmp.as_deref(),
            canonical_manifest_dir.as_deref(),
        ) {
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

// Resolved once per walk, not per ancestor; `cfg!(test)`-gated because these boundaries only
// ever gate this crate's own test fixtures and production installs shouldn't pay for the syscall.
fn canonical_test_boundary(path: &Path) -> Option<PathBuf> {
    if cfg!(test) {
        path.canonicalize().ok()
    } else {
        None
    }
}

fn is_test_temp_boundary(
    path: &Path,
    metadata: &Metadata,
    canonical_temp_dir: Option<&Path>,
    canonical_tmp: Option<&Path>,
    canonical_manifest_dir: Option<&Path>,
) -> bool {
    if !cfg!(test) {
        return false;
    }
    // Match each boundary's canonical form too, not just its raw spelling: a caller may hand
    // this walk a path that was already resolved by its own `canonicalize()`, in which case the
    // raw special path never appears as an ancestor even when we're really looking at the same
    // directory.
    let secure_session_temp = (path == temp_dir() || canonical_temp_dir == Some(path))
        && metadata.uid() == trusted_owner().0
        && metadata.mode() & 0o022 == 0;
    let sticky_system_temp = (path == Path::new("/tmp") || canonical_tmp == Some(path))
        && metadata.uid() == 0
        && metadata.mode() & 0o1000 != 0;
    // `hardened_tempdir_in(CARGO_MANIFEST_DIR)` fixtures sit inside the crate's own checkout,
    // whose mode tracks the host umask. That's the developer's or CI's own tree, not attacker
    // controlled, so trust it regardless of write bits.
    let crate_manifest_dir = (path == Path::new(env!("CARGO_MANIFEST_DIR"))
        || canonical_manifest_dir == Some(path))
        && metadata.uid() == trusted_owner().0;
    secure_session_temp || sticky_system_temp || crate_manifest_dir
}
