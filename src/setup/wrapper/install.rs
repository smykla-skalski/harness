use std::collections::HashSet;
use std::fs::Permissions;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use fs_err as fs;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::write_text;
use crate::workspace::dirs_home;

use super::WRAPPER;

/// Choose the install directory for the harness wrapper.
///
/// Prefers `~/.local/bin` or `~/bin` if they are on PATH and writable.
/// Falls back to any writable user PATH directory, then `~/.local/bin`
/// unconditionally.
///
/// Returns `(target_dir, already_on_path)`.
///
/// # Errors
/// Returns `CliError` if no suitable directory is found.
pub fn choose_install_dir_with_home(
    path_env: &str,
    home: &Path,
) -> Result<(PathBuf, bool), CliError> {
    let home = canonical_or_same(home);
    let path_dirs = path_candidates(path_env);
    let preferred = [home.join(".local").join("bin"), home.join("bin")];

    for pref in &preferred {
        let canonical_pref = canonical_or_same(pref);
        if path_dirs
            .iter()
            .any(|p| canonical_or_same(p) == canonical_pref)
            && is_installable(pref)
        {
            return Ok((pref.clone(), true));
        }
    }

    for path_dir in &path_dirs {
        let canonical_dir = canonical_or_same(path_dir);
        if canonical_dir.starts_with(&home) && is_installable(path_dir) {
            return Ok((path_dir.clone(), true));
        }
    }

    let fallback = &preferred[0];
    if is_installable(fallback) {
        let canonical_fallback = canonical_or_same(fallback);
        let on_path = path_dirs
            .iter()
            .any(|p| canonical_or_same(p) == canonical_fallback);
        return Ok((fallback.clone(), on_path));
    }

    Err(CliErrorKind::missing_file("no writable user PATH directory found").into())
}

/// Install the harness wrapper script into the target directory.
///
/// Creates the directory if needed, writes the wrapper, and sets it
/// executable. If the wrapper already has the right content, only
/// ensures the executable bit.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn install_wrapper(target_dir: &Path) -> Result<PathBuf, CliError> {
    fs::create_dir_all(target_dir)?;

    let target = target_dir.join("harness");

    if target.exists() {
        let meta = fs::metadata(&target)?;
        let mut perms = meta.permissions();
        perms.set_mode(perms.mode() | 0o111);
        fs::set_permissions(&target, perms)?;
        return Ok(target);
    }

    write_text(&target, WRAPPER)?;
    fs::set_permissions(&target, Permissions::from_mode(0o755))?;
    Ok(target)
}

pub(super) fn path_candidates(path_env: &str) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    let mut candidates = Vec::new();
    for raw in path_env.split(':') {
        if raw.is_empty() {
            continue;
        }
        let path = expand_path(raw);
        if seen.insert(path.clone()) {
            candidates.push(path);
        }
    }
    candidates
}

fn expand_path(raw: &str) -> PathBuf {
    let path = PathBuf::from(raw);
    if raw.starts_with('~') {
        let home = dirs_home();
        let stripped = raw.strip_prefix("~/").unwrap_or("~");
        if stripped == "~" {
            return home;
        }
        return home.join(stripped);
    }
    fs::canonicalize(&path).unwrap_or(path)
}

fn is_installable(path: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;

    if path.exists() {
        if !path.is_dir() {
            return false;
        }
        if let Ok(meta) = path.metadata() {
            let mode = meta.mode();
            if meta.uid() == uzers::get_current_uid() {
                return mode & 0o300 == 0o300;
            }
            return mode & 0o011 != 0;
        }
        return false;
    }

    if let Some(parent) = path.parent() {
        return is_installable(parent);
    }
    false
}

fn canonical_or_same(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}
