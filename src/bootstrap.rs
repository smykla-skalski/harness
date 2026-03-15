use std::collections::HashSet;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use crate::core_defs::dirs_home;
use crate::errors::{CliError, CliErrorKind, cow};

/// Shell wrapper script that delegates to the project-local harness binary.
pub const WRAPPER: &str = r#"#!/bin/sh
set -eu

if [ "${CLAUDE_PROJECT_DIR:-}" ]; then
  candidate="${CLAUDE_PROJECT_DIR}/.claude/skills/harness"
  if [ -x "${candidate}" ]; then
    exec "${candidate}" "$@"
  fi
fi

if command -v git >/dev/null 2>&1; then
  if repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    candidate="${repo_root}/.claude/skills/harness"
    if [ -x "${candidate}" ]; then
      exec "${candidate}" "$@"
    fi
  fi
fi

echo "harness: unable to resolve .claude/skills/harness" >&2
echo "from CLAUDE_PROJECT_DIR or the current git repo" >&2
exit 1
"#;

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
pub fn choose_install_dir(path_env: &str) -> Result<(PathBuf, bool), CliError> {
    choose_install_dir_with_home(path_env, &dirs_home())
}

/// Like [`choose_install_dir`] but accepts an explicit `home` directory so
/// callers (and tests) don't depend on the ambient `HOME` env var.
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

    if target.exists()
        && let Ok(existing) = fs::read_to_string(&target)
        && existing == WRAPPER
    {
        // Just ensure executable
        let meta = fs::metadata(&target)?;
        let mut perms = meta.permissions();
        perms.set_mode(perms.mode() | 0o111);
        fs::set_permissions(&target, perms)?;
        return Ok(target);
    }

    fs::write(&target, WRAPPER)?;
    fs::set_permissions(&target, fs::Permissions::from_mode(0o755))?;
    Ok(target)
}

/// Bootstrap main entry point.
///
/// Verifies the project source wrapper exists, chooses an install dir,
/// and installs the wrapper.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn main(project_dir: &Path, path_env: &str) -> Result<i32, CliError> {
    main_with_home(project_dir, path_env, &dirs_home())
}

/// Like [`main`] but accepts an explicit `home` directory for testability.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn main_with_home(project_dir: &Path, path_env: &str, home: &Path) -> Result<i32, CliError> {
    let harness = project_dir.join(".claude").join("skills").join("harness");
    if !harness.exists() {
        return Err(CliErrorKind::missing_file(cow!(
            "missing source wrapper: {}",
            harness.display()
        ))
        .into());
    }

    let (target_dir, _already_on_path) = choose_install_dir_with_home(path_env, home)?;
    install_wrapper(&target_dir)?;
    Ok(0)
}

fn path_candidates(path_env: &str) -> Vec<PathBuf> {
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
        // Check writable + executable
        if let Ok(meta) = path.metadata() {
            let mode = meta.mode();
            if meta.uid() == uzers::get_current_uid() {
                return mode & 0o300 == 0o300;
            }
            // Fallback: try to check group/other
            return mode & 0o011 != 0;
        }
        return false;
    }

    // Directory doesn't exist yet - check if parent is writable
    if let Some(parent) = path.parent() {
        return parent.exists() && is_installable(parent);
    }
    false
}

fn canonical_or_same(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrapper_content_starts_with_shebang() {
        assert!(WRAPPER.starts_with("#!/bin/sh"));
    }

    #[test]
    fn wrapper_content_references_claude_project_dir() {
        assert!(WRAPPER.contains("CLAUDE_PROJECT_DIR"));
    }

    #[test]
    fn wrapper_content_references_git_rev_parse() {
        assert!(WRAPPER.contains("git rev-parse --show-toplevel"));
    }

    #[test]
    fn choose_install_dir_prefers_local_bin_on_path() {
        let dir = tempfile::tempdir().unwrap();
        let local_bin = dir.path().join(".local").join("bin");
        fs::create_dir_all(&local_bin).unwrap();

        let path_env = local_bin.to_string_lossy().into_owned();
        let (chosen, on_path) = choose_install_dir_with_home(&path_env, dir.path()).unwrap();
        // Canonicalize both to handle macOS /private/var vs /var symlink
        assert_eq!(
            chosen.canonicalize().unwrap_or(chosen),
            local_bin.canonicalize().unwrap_or(local_bin)
        );
        assert!(on_path);
    }

    #[test]
    fn install_wrapper_creates_executable_file() {
        let dir = tempfile::tempdir().unwrap();
        let target_dir = dir.path().join("bin");

        let path = install_wrapper(&target_dir).unwrap();

        assert!(path.exists());
        assert_eq!(fs::read_to_string(&path).unwrap(), WRAPPER);
        let mode = fs::metadata(&path).unwrap().permissions().mode();
        assert_ne!(mode & 0o111, 0, "should be executable");
    }

    #[test]
    fn install_wrapper_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let target_dir = dir.path().join("bin");

        let first = install_wrapper(&target_dir).unwrap();
        let second = install_wrapper(&target_dir).unwrap();

        assert_eq!(first, second);
        assert_eq!(fs::read_to_string(&first).unwrap(), WRAPPER);
    }

    #[test]
    fn install_wrapper_overwrites_different_content() {
        let dir = tempfile::tempdir().unwrap();
        let target_dir = dir.path().join("bin");
        fs::create_dir_all(&target_dir).unwrap();
        fs::write(target_dir.join("harness"), "old content").unwrap();

        let path = install_wrapper(&target_dir).unwrap();
        assert_eq!(fs::read_to_string(path).unwrap(), WRAPPER);
    }

    #[test]
    fn main_fails_when_source_wrapper_missing() {
        let dir = tempfile::tempdir().unwrap();
        let err = main(dir.path(), "").unwrap_err();
        assert!(err.message().contains("missing source wrapper"));
    }

    #[test]
    fn main_succeeds_with_valid_project() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join(".claude").join("skills").join("harness");
        fs::create_dir_all(source.parent().unwrap()).unwrap();
        fs::write(&source, "#!/bin/sh\necho ok\n").unwrap();

        let bin_dir = dir.path().join(".local").join("bin");
        fs::create_dir_all(&bin_dir).unwrap();

        let path_env = bin_dir.to_string_lossy().into_owned();
        let result = main_with_home(dir.path(), &path_env, dir.path());

        assert_eq!(result.unwrap(), 0);
        assert!(bin_dir.join("harness").exists());
    }

    #[test]
    fn path_candidates_deduplicates() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        fs::create_dir_all(&bin).unwrap();
        let path_str = format!("{}:{}", bin.display(), bin.display());
        let candidates = path_candidates(&path_str);
        assert_eq!(candidates.len(), 1);
    }

    #[test]
    fn path_candidates_skips_empty_entries() {
        let candidates = path_candidates(":/usr/bin:");
        // Only /usr/bin should appear
        assert!(!candidates.is_empty());
        assert!(candidates.iter().all(|p| !p.as_os_str().is_empty()));
    }
}
