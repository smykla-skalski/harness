use std::env;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use tokio::fs;
use tokio::process::Command;

/// Environment variable that points at a custom `harness-monitor-input`
/// binary. When set and the target file exists, it wins over the default
/// search paths.
pub const INPUT_OVERRIDE_ENV: &str = "HARNESS_MONITOR_INPUT_BIN";

/// Selected input backend in preference order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Backend {
    /// Path to the `harness-monitor-input` Swift helper.
    HarnessInput(PathBuf),
    /// `cliclick` found on `PATH`. No path is captured because the binary
    /// is expected to be invoked by bare name.
    Cliclick,
    /// No mouse backend is available.
    None,
}

impl Backend {
    #[must_use]
    pub fn is_none(&self) -> bool {
        matches!(self, Self::None)
    }
}

/// Probe the environment and filesystem to pick the best input backend.
/// Order: `$HARNESS_MONITOR_INPUT_BIN` > bundled helper under the registry
/// package > `cliclick` on PATH > None.
pub async fn detect_backend() -> Backend {
    if let Some(path) = env_override()
        && file_exists(&path).await
    {
        return Backend::HarnessInput(path);
    }
    if let Some(candidate) = default_helper_candidate().await {
        return Backend::HarnessInput(candidate);
    }
    if on_path("cliclick").await {
        return Backend::Cliclick;
    }
    Backend::None
}

fn env_override() -> Option<PathBuf> {
    let value = env::var_os(INPUT_OVERRIDE_ENV)?;
    if value.is_empty() {
        return None;
    }
    Some(PathBuf::from(value))
}

pub(crate) async fn default_helper_candidate() -> Option<PathBuf> {
    for root in helper_search_roots() {
        if let Some(candidate) = default_helper_candidate_in(&root).await {
            return Some(candidate);
        }
    }
    None
}

pub(crate) async fn default_helper_candidate_in(repo_root: &Path) -> Option<PathBuf> {
    let mut best: Option<(SystemTime, PathBuf)> = None;
    for candidate in helper_candidates_from(repo_root) {
        let Ok(metadata) = fs::metadata(&candidate).await else {
            continue;
        };
        let modified = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
        if best.as_ref().is_none_or(|(best_modified, best_path)| {
            modified > *best_modified
                || (modified == *best_modified
                    && prefers_candidate(&candidate, best_path))
        }) {
            best = Some((modified, candidate));
        }
    }
    best.map(|(_, path)| path)
}

fn helper_candidates_from(repo_root: &Path) -> Vec<PathBuf> {
    // The Node.js server walked up from `dist/automation.js` to the package
    // root, then across to `harness-monitor-registry`. In the Rust CLI we
    // don't have a package-local install path, so we look under the
    // repository sibling `mcp-servers/harness-monitor-registry/.build`.
    let registry = repo_root.join("mcp-servers/harness-monitor-registry/.build");
    let mut candidates = platform_helper_candidates(&registry);
    candidates.extend([
        registry.join("release/harness-monitor-input"),
        registry.join("debug/harness-monitor-input"),
    ]);
    candidates
}

fn platform_helper_candidates(build_root: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(build_root) else {
        return Vec::new();
    };

    let mut candidates = Vec::new();
    for entry in entries.flatten() {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if !file_type.is_dir() {
            continue;
        }
        let path = entry.path();
        candidates.extend([
            path.join("release/harness-monitor-input"),
            path.join("debug/harness-monitor-input"),
        ]);
    }
    candidates
}

fn prefers_candidate(candidate: &Path, incumbent: &Path) -> bool {
    candidate.components().any(|component| component.as_os_str() == "debug")
        && !incumbent
            .components()
            .any(|component| component.as_os_str() == "debug")
}

fn helper_search_roots() -> Vec<PathBuf> {
    helper_search_roots_from(env::current_dir().ok(), env::current_exe().ok())
}

pub(crate) fn helper_search_roots_from(
    current_dir: Option<PathBuf>,
    current_exe: Option<PathBuf>,
) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    push_unique_ancestors(current_exe.as_deref().and_then(Path::parent), &mut roots);
    push_unique_ancestors(current_dir.as_deref(), &mut roots);
    roots
}

fn push_unique_ancestors(start: Option<&Path>, roots: &mut Vec<PathBuf>) {
    let Some(start) = start else {
        return;
    };
    for ancestor in start.ancestors() {
        if !roots.iter().any(|root| root == ancestor) {
            roots.push(ancestor.to_path_buf());
        }
    }
}

async fn file_exists(path: &Path) -> bool {
    fs::metadata(path).await.is_ok()
}

async fn on_path(cmd: &str) -> bool {
    Command::new("/usr/bin/which")
        .arg(cmd)
        .output()
        .await
        .is_ok_and(|out| out.status.success())
}
