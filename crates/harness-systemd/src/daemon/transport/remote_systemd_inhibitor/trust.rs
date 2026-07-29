use std::fs::Metadata;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};

use fs_err as fs;

use crate::errors::CliError;

use super::{io_error, trusted_uid};

pub(super) fn validate_unit_directory(unit_path: &Path) -> Result<&Path, CliError> {
    let parent = unit_path.parent().ok_or_else(|| {
        io_error(format!(
            "systemd unit path has no parent: {}",
            unit_path.display()
        ))
    })?;
    let canonical_manifest_dir = canonical_test_boundary(Path::new(env!("CARGO_MANIFEST_DIR")));
    for ancestor in parent.ancestors() {
        if validate_trusted_ancestor(ancestor, canonical_manifest_dir.as_deref())? {
            break;
        }
    }
    Ok(parent)
}

// Resolved once per walk, not per ancestor; `cfg!(test)`-gated because this boundary only ever
// gates this crate's own test fixtures and production installs shouldn't pay for the syscall.
fn canonical_test_boundary(path: &Path) -> Option<PathBuf> {
    if cfg!(test) {
        path.canonicalize().ok()
    } else {
        None
    }
}

/// Returns `Ok(true)` once the walk reaches a boundary trusted without a writability check.
fn validate_trusted_ancestor(
    path: &Path,
    canonical_manifest_dir: Option<&Path>,
) -> Result<bool, CliError> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        io_error(format!(
            "inspect systemd unit directory ancestor {}: {error}",
            path.display()
        ))
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(io_error(format!(
            "systemd unit directory ancestor is not a real directory: {}",
            path.display()
        )));
    }
    if metadata.uid() != 0 && metadata.uid() != trusted_uid() {
        return Err(io_error(format!(
            "systemd unit directory ancestor has untrusted owner {}: {}",
            metadata.uid(),
            path.display()
        )));
    }
    if is_test_manifest_dir_boundary(path, &metadata, canonical_manifest_dir) {
        return Ok(true);
    }
    let trusted_sticky_root = metadata.uid() == 0 && metadata.mode() & 0o1000 != 0;
    if metadata.mode() & 0o022 != 0 && !trusted_sticky_root {
        return Err(io_error(format!(
            "systemd unit directory ancestor is group- or world-writable: {}",
            path.display()
        )));
    }
    Ok(false)
}

// `hardened_tempdir_in(CARGO_MANIFEST_DIR)` fixtures sit inside the crate's own checkout, whose
// mode tracks the host umask (e.g. 002 leaves a worktree group-writable). That's the developer's
// or CI's own tree, not attacker controlled, so trust it as a boundary regardless of write bits.
// Match the canonical form too: a caller may hand this walk a path already resolved by its own
// `canonicalize()`, in which case the raw manifest dir never appears as an ancestor even when
// we're really looking at the same directory.
fn is_test_manifest_dir_boundary(
    path: &Path,
    metadata: &Metadata,
    canonical_manifest_dir: Option<&Path>,
) -> bool {
    cfg!(test)
        && (path == Path::new(env!("CARGO_MANIFEST_DIR")) || canonical_manifest_dir == Some(path))
        && metadata.uid() == trusted_uid()
}
