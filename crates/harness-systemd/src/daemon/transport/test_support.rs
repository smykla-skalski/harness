use std::env::temp_dir;
use std::fs::{Permissions, set_permissions};
use std::io;
use std::os::unix::fs::PermissionsExt as _;
use std::path::Path;

use nix::sys::stat::{Mode, umask};
use tempfile::TempDir;

// `tempfile::tempdir[_in]` derives the created directory's mode from the process umask, so a
// shared multi-user umask (e.g. 002) leaves it group- or world-writable. Every fixture in this
// crate feeds its returned path into `validate_trusted_ancestors`, which rejects exactly that,
// so the crate's own test suite would otherwise fail wholesale on such a host regardless of the
// change under test.
//
// Pinning the mode of the returned directory alone is not enough: fixtures routinely create
// further subdirectories underneath it (`fs::create_dir_all`), and `mkdir` always derives from
// the ambient umask regardless of the parent's own mode. Pin the process umask itself to a known
// value before creating the fixture, which nextest's one-process-per-test model makes safe to do
// unconditionally - it protects every directory this test creates afterward, not just this one.
// This can loosen a stricter ambient umask (e.g. 0o077), but nothing here relies on directories
// coming out more restrictive than 0o755, so that's fine.
const HARDENED_MODE: u32 = 0o755;

pub(crate) fn hardened_tempdir() -> io::Result<TempDir> {
    hardened_tempdir_in(temp_dir())
}

pub(crate) fn hardened_tempdir_in(path: impl AsRef<Path>) -> io::Result<TempDir> {
    pin_umask();
    // macOS reports its temporary root through `/var`, a symlink to `/private/var`. Resolve the
    // fixture parent so path-hardening tests only see aliases they created deliberately.
    let parent = path.as_ref().canonicalize()?;
    let dir = tempfile::tempdir_in(parent)?;
    harden(dir.path())?;
    Ok(dir)
}

fn pin_umask() {
    umask(Mode::from_bits_truncate(0o022));
}

fn harden(path: &Path) -> io::Result<()> {
    set_permissions(path, Permissions::from_mode(HARDENED_MODE))
}
