//! Write-surface policy evaluation.
//!
//! Single free function consumed by both TUI hook write guards and the ACP
//! `Client::write_text_file` handler. No trait, no abstraction layer: if a
//! third caller needs different semantics, factor then. — tef + antirez.
//!
//! Drift integration test (`tests/integration/policy_drift.rs`) catches
//! divergence by feeding the same nasty-input fixtures through both call
//! paths.

use std::collections::BTreeSet;
use std::io;
use std::path::{Component, Path, PathBuf};

use crate::kernel::run_surface::{RunDir, RunFile};

/// Result of evaluating a write request against the run surface.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WriteDecision {
    /// Write is allowed within the run surface.
    Allow,
    /// Write denied because the path is a harness-managed control file.
    DenyControlFile {
        /// Human-readable hint for how to accomplish the write correctly.
        hint: &'static str,
    },
    /// Write denied because the path escapes the run surface.
    DenyOutsideSurface,
    /// Write denied because the path traverses outside via `..` segments.
    DenyTraversal,
    /// Write denied because the target would be a denied binary.
    DenyBinary {
        /// Name of the denied binary.
        name: String,
    },
    /// Write denied because a symlink resolves outside the run surface.
    DenySymlinkEscape {
        /// Where the symlink resolved to.
        resolved: PathBuf,
    },
    /// Write denied because the policy check failed (e.g., symlink canonicalize error).
    /// Security guards must fail closed, not open.
    DenyCheckFailed {
        /// Human-readable reason for the failure.
        reason: String,
    },
}

impl WriteDecision {
    #[must_use]
    pub const fn is_allow(&self) -> bool {
        matches!(self, Self::Allow)
    }

    #[must_use]
    pub const fn is_deny(&self) -> bool {
        !self.is_allow()
    }
}

/// Wrapper for the set of denied binary names.
///
/// The set is produced by `managed_cluster_binaries()` in
/// `hooks/runner_policy/cluster.rs`. ACP callers build the same set from
/// `BlockRequirement::denied_binaries()`.
#[derive(Debug, Clone)]
pub struct DeniedBinaries(BTreeSet<String>);

impl DeniedBinaries {
    #[must_use]
    pub fn new(names: BTreeSet<String>) -> Self {
        Self(names)
    }

    #[must_use]
    pub fn contains(&self, name: &str) -> bool {
        self.0.contains(name)
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl From<BTreeSet<String>> for DeniedBinaries {
    fn from(set: BTreeSet<String>) -> Self {
        Self::new(set)
    }
}

/// Context for write-surface evaluation.
///
/// Holds the run directory and optional suite directory against which
/// path checks are performed. Normalized paths are cached at construction
/// to avoid redundant computation per evaluation.
#[derive(Debug, Clone)]
pub struct WriteSurfaceContext<'a> {
    /// Root of the run directory (e.g. `~/.local/share/harness/runs/<id>`).
    pub run_dir: &'a Path,
    /// Cached normalized form of `run_dir`.
    run_dir_normalized: PathBuf,
    /// Optional suite directory. Writes inside suite dir are allowed when
    /// a run is active.
    pub suite_dir: Option<&'a Path>,
    /// Cached normalized form of `suite_dir` (if present).
    suite_dir_normalized: Option<PathBuf>,
}

impl<'a> WriteSurfaceContext<'a> {
    #[must_use]
    pub fn new(run_dir: &'a Path) -> Self {
        Self {
            run_dir,
            run_dir_normalized: normalize_path(run_dir),
            suite_dir: None,
            suite_dir_normalized: None,
        }
    }

    #[must_use]
    pub fn with_suite_dir(mut self, suite_dir: &'a Path) -> Self {
        self.suite_dir = Some(suite_dir);
        self.suite_dir_normalized = Some(normalize_path(suite_dir));
        self
    }
}

/// Normalize a path by resolving `.` and `..` segments without touching the
/// filesystem. Unlike `std::fs::canonicalize`, this works on paths that do not
/// exist yet.
fn normalize_path(path: &Path) -> PathBuf {
    let mut parts: Vec<Component<'_>> = Vec::new();
    for comp in path.components() {
        match comp {
            Component::CurDir => {}
            Component::ParentDir => {
                if let Some(Component::Normal(_)) = parts.last() {
                    parts.pop();
                } else {
                    parts.push(comp);
                }
            }
            _ => parts.push(comp),
        }
    }
    parts.iter().collect()
}

/// Check if a path uses `..` segments that escape its anchor.
fn has_escaping_traversal(path: &Path, anchor_normalized: &Path) -> bool {
    // Only count as traversal if the path contains `..` AND escapes
    let has_parent_segments = path.components().any(|c| matches!(c, Component::ParentDir));
    if !has_parent_segments {
        return false;
    }
    let normalized = normalize_path(path);
    !normalized.starts_with(anchor_normalized)
}

/// Check if a symlink resolves outside the allowed surface.
fn symlink_escapes(path: &Path, anchor: &Path) -> Result<Option<PathBuf>, io::Error> {
    if !path.is_symlink() {
        return Ok(None);
    }
    let resolved = path.canonicalize()?;
    let anchor_canonical = anchor.canonicalize()?;
    if !resolved.starts_with(&anchor_canonical) {
        return Ok(Some(resolved));
    }
    Ok(None)
}

/// Check if the path is a harness-managed control file.
fn is_control_file(path: &Path, run_dir: &Path) -> Option<&'static str> {
    let normalized = normalize_path(path);
    for file in RunFile::ALL.iter().filter(|f| f.is_direct_write_denied()) {
        let control_path = normalize_path(&run_dir.join(file.to_string()));
        if normalized == control_path {
            return Some(file.write_hint());
        }
    }
    None
}

/// Check if the path is within an allowed run subdirectory.
fn is_in_allowed_run_dir(path: &Path, run_dir: &Path) -> bool {
    let normalized = normalize_path(path);
    let run_dir_normalized = normalize_path(run_dir);

    // Check allowed files first
    for file in RunFile::ALL.iter().filter(|f| f.is_allowed()) {
        let file_path = normalize_path(&run_dir_normalized.join(file.to_string()));
        if normalized == file_path {
            return true;
        }
    }

    // Check allowed directories
    for dir in RunDir::ALL {
        let dir_path = normalize_path(&run_dir_normalized.join(dir.to_string()));
        if normalized.starts_with(&dir_path) {
            return true;
        }
    }

    false
}

/// Check if writing a file would create a denied binary.
fn would_create_denied_binary(path: &Path, denied: &DeniedBinaries) -> Option<String> {
    let file_name = path.file_name()?.to_str()?;
    if denied.contains(file_name) {
        return Some(file_name.to_string());
    }
    None
}

/// Check path against `suite_dir` surface. Returns `Some(decision)` if `suite_dir`
/// applies, `None` otherwise.
fn check_suite_dir_surface(
    path: &Path,
    normalized: &Path,
    suite_dir: &Path,
    suite_dir_normalized: &Path,
    denied: &DeniedBinaries,
) -> Option<WriteDecision> {
    if !normalized.starts_with(suite_dir_normalized) {
        return None;
    }
    if let Some(name) = would_create_denied_binary(path, denied) {
        return Some(WriteDecision::DenyBinary { name });
    }
    match symlink_escapes(path, suite_dir) {
        Ok(Some(resolved)) => return Some(WriteDecision::DenySymlinkEscape { resolved }),
        Ok(None) => {}
        Err(e) => {
            return Some(WriteDecision::DenyCheckFailed {
                reason: format!("symlink check failed: {e}"),
            });
        }
    }
    Some(WriteDecision::Allow)
}

/// Check path against `run_dir` surface for final decisions.
fn check_run_dir_surface(path: &Path, run_dir: &Path, denied: &DeniedBinaries) -> WriteDecision {
    if let Some(hint) = is_control_file(path, run_dir) {
        return WriteDecision::DenyControlFile { hint };
    }
    if !is_in_allowed_run_dir(path, run_dir) {
        return WriteDecision::DenyOutsideSurface;
    }
    match symlink_escapes(path, run_dir) {
        Ok(Some(resolved)) => return WriteDecision::DenySymlinkEscape { resolved },
        Ok(None) => {}
        Err(e) => {
            return WriteDecision::DenyCheckFailed {
                reason: format!("symlink check failed: {e}"),
            };
        }
    }
    if let Some(name) = would_create_denied_binary(path, denied) {
        return WriteDecision::DenyBinary { name };
    }
    WriteDecision::Allow
}

/// Evaluate whether a write to `path` is allowed.
///
/// This is the single source of truth for write-surface policy. TUI hook
/// `guard-write` and ACP `Client::write_text_file` both call this function.
///
/// # Arguments
///
/// * `path` - The path the caller wants to write to.
/// * `ctx` - Context containing the run directory and optional suite directory.
/// * `denied` - Set of binary names that cannot be created/overwritten.
///
/// # Returns
///
/// `WriteDecision::Allow` if the write should proceed, or a denial variant
/// with diagnostic information otherwise.
#[must_use]
pub fn evaluate_write(
    path: &Path,
    ctx: &WriteSurfaceContext<'_>,
    denied: &DeniedBinaries,
) -> WriteDecision {
    let run_dir = ctx.run_dir;
    let normalized = normalize_path(path);
    let run_dir_normalized = &ctx.run_dir_normalized;

    // Check for traversal escape
    if has_escaping_traversal(path, run_dir_normalized) {
        if let Some(suite_dir) = ctx.suite_dir
            && let Some(ref suite_dir_normalized) = ctx.suite_dir_normalized
            && let Some(decision) =
                check_suite_dir_surface(path, &normalized, suite_dir, suite_dir_normalized, denied)
        {
            return decision;
        }
        return WriteDecision::DenyTraversal;
    }

    // Check if path is within run_dir
    if !normalized.starts_with(run_dir_normalized) {
        if let Some(suite_dir) = ctx.suite_dir
            && let Some(ref suite_dir_normalized) = ctx.suite_dir_normalized
            && let Some(decision) =
                check_suite_dir_surface(path, &normalized, suite_dir, suite_dir_normalized, denied)
        {
            return decision;
        }
        return WriteDecision::DenyOutsideSurface;
    }

    check_run_dir_surface(path, run_dir, denied)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use tempfile::TempDir;

    use super::*;

    fn empty_denied() -> DeniedBinaries {
        DeniedBinaries::new(BTreeSet::new())
    }

    fn denied_with(names: &[&str]) -> DeniedBinaries {
        DeniedBinaries::new(names.iter().map(|s| (*s).to_string()).collect())
    }

    fn setup_run_dir() -> TempDir {
        let temp = TempDir::new().expect("create temp dir");
        let run_dir = temp.path();
        fs::create_dir_all(run_dir.join("artifacts")).expect("create artifacts");
        fs::create_dir_all(run_dir.join("commands")).expect("create commands");
        fs::create_dir_all(run_dir.join("manifests")).expect("create manifests");
        fs::create_dir_all(run_dir.join("state")).expect("create state");
        temp
    }

    #[test]
    fn allow_write_to_artifacts_dir() {
        let temp = setup_run_dir();
        let run_dir = temp.path();
        let ctx = WriteSurfaceContext::new(run_dir);
        let path = run_dir.join("artifacts/output.json");
        assert_eq!(
            evaluate_write(&path, &ctx, &empty_denied()),
            WriteDecision::Allow
        );
    }

    #[test]
    fn allow_write_to_commands_dir() {
        let temp = setup_run_dir();
        let run_dir = temp.path();
        let ctx = WriteSurfaceContext::new(run_dir);
        let path = run_dir.join("commands/cmd.sh");
        assert_eq!(
            evaluate_write(&path, &ctx, &empty_denied()),
            WriteDecision::Allow
        );
    }

    #[test]
    fn deny_write_to_control_file_run_status() {
        let temp = setup_run_dir();
        let run_dir = temp.path();
        let ctx = WriteSurfaceContext::new(run_dir);
        let path = run_dir.join("run-status.json");
        let result = evaluate_write(&path, &ctx, &empty_denied());
        assert!(matches!(result, WriteDecision::DenyControlFile { .. }));
    }

    #[test]
    fn deny_write_to_control_file_run_report() {
        let temp = setup_run_dir();
        let run_dir = temp.path();
        let ctx = WriteSurfaceContext::new(run_dir);
        let path = run_dir.join("run-report.md");
        let result = evaluate_write(&path, &ctx, &empty_denied());
        assert!(matches!(result, WriteDecision::DenyControlFile { .. }));
    }

    #[test]
    fn deny_write_outside_run_dir() {
        let temp = setup_run_dir();
        let run_dir = temp.path();
        let ctx = WriteSurfaceContext::new(run_dir);
        let path = PathBuf::from("/tmp/outside.txt");
        assert_eq!(
            evaluate_write(&path, &ctx, &empty_denied()),
            WriteDecision::DenyOutsideSurface
        );
    }

    #[test]
    fn deny_traversal_escape() {
        let temp = setup_run_dir();
        let run_dir = temp.path();
        let ctx = WriteSurfaceContext::new(run_dir);
        let path = run_dir.join("artifacts/../../../etc/passwd");
        assert_eq!(
            evaluate_write(&path, &ctx, &empty_denied()),
            WriteDecision::DenyTraversal
        );
    }

    #[test]
    fn deny_denied_binary() {
        let temp = setup_run_dir();
        let run_dir = temp.path();
        let ctx = WriteSurfaceContext::new(run_dir);
        let denied = denied_with(&["kubectl", "kumactl"]);
        let path = run_dir.join("artifacts/kubectl");
        let result = evaluate_write(&path, &ctx, &denied);
        assert!(matches!(result, WriteDecision::DenyBinary { name } if name == "kubectl"));
    }

    #[test]
    fn allow_with_suite_dir() {
        let temp = setup_run_dir();
        let run_dir = temp.path();
        let suite_temp = TempDir::new().expect("suite temp");
        let suite_dir = suite_temp.path();
        let ctx = WriteSurfaceContext::new(run_dir).with_suite_dir(suite_dir);
        let path = suite_dir.join("test.yaml");
        assert_eq!(
            evaluate_write(&path, &ctx, &empty_denied()),
            WriteDecision::Allow
        );
    }

    #[test]
    fn normalize_removes_dot_segments() {
        let input = Path::new("/a/b/./c");
        let expected = PathBuf::from("/a/b/c");
        assert_eq!(normalize_path(input), expected);
    }

    #[test]
    fn normalize_resolves_dotdot_segments() {
        let input = Path::new("/a/b/../c");
        let expected = PathBuf::from("/a/c");
        assert_eq!(normalize_path(input), expected);
    }

    #[test]
    fn symlink_escape_detection() {
        let temp = setup_run_dir();
        let run_dir = temp.path();

        // Create a symlink inside run_dir pointing outside
        let outside = TempDir::new().expect("outside temp");
        let outside_file = outside.path().join("secret.txt");
        fs::write(&outside_file, "secret").expect("write secret");

        let link_path = run_dir.join("artifacts/link");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside_file, &link_path).expect("create symlink");

        #[cfg(unix)]
        {
            let result = symlink_escapes(&link_path, run_dir);
            assert!(result.is_ok());
            let escaped = result.unwrap();
            assert!(escaped.is_some(), "symlink should escape");
        }
    }
}
