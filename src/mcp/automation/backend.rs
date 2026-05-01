use std::collections::HashSet;
use std::env;
use std::fs::read_dir;
use std::fs::Metadata;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use tokio::fs;
use tokio::process::Command;
use tokio::time::{Duration, timeout};

/// Environment variable that points at a custom `harness-monitor-input`
/// binary. When set and the target file exists, it wins over the default
/// search paths.
pub const INPUT_OVERRIDE_ENV: &str = "HARNESS_MONITOR_INPUT_BIN";
const HELPER_PROBE_TIMEOUT: Duration = Duration::from_secs(1);

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
        && viable_helper_candidate(&path).await.is_some()
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
    default_helper_candidate_from_roots(&helper_search_roots()).await
}

#[cfg_attr(
    not(test),
    expect(dead_code, reason = "exercised by automation tests to lock helper ranking")
)]
pub(crate) async fn default_helper_candidate_in(repo_root: &Path) -> Option<PathBuf> {
    best_helper_candidate(helper_candidates_from(repo_root)).await
}

pub(crate) async fn default_helper_candidate_from_roots(roots: &[PathBuf]) -> Option<PathBuf> {
    let mut seen = HashSet::new();
    let candidates: Vec<PathBuf> = roots
        .iter()
        .flat_map(|root| helper_candidates_from(root))
        .filter(|candidate| seen.insert(candidate.clone()))
        .collect();
    best_helper_candidate(candidates).await
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
    let Ok(entries) = read_dir(build_root) else {
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

async fn best_helper_candidate<I>(candidates: I) -> Option<PathBuf>
where
    I: IntoIterator<Item = PathBuf>,
{
    let mut best: Option<(SystemTime, PathBuf)> = None;
    for candidate in candidates {
        let Some((modified, candidate)) = viable_helper_candidate(&candidate).await else {
            continue;
        };
        if best.as_ref().is_none_or(|(best_modified, best_path)| {
            modified > *best_modified
                || (modified == *best_modified && prefers_candidate(&candidate, best_path))
        }) {
            best = Some((modified, candidate));
        }
    }
    best.map(|(_, path)| path)
}

async fn viable_helper_candidate(path: &Path) -> Option<(SystemTime, PathBuf)> {
    let metadata = fs::metadata(path).await.ok()?;
    if !metadata.is_file() || !is_executable(&metadata) {
        return None;
    }
    if !helper_launches(path).await {
        return None;
    }
    Some((metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH), path.to_path_buf()))
}

#[cfg(unix)]
fn is_executable(metadata: &Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;

    metadata.permissions().mode() & 0o111 != 0
}

#[cfg(not(unix))]
fn is_executable(_metadata: &Metadata) -> bool {
    true
}

async fn helper_launches(path: &Path) -> bool {
    timeout(
        HELPER_PROBE_TIMEOUT,
        Command::new(path).arg("--help").output(),
    )
    .await
    .is_ok_and(|output| output.is_ok_and(|output| output.status.success()))
}

fn helper_search_roots() -> Vec<PathBuf> {
    let current_dir = env::current_dir().ok();
    let current_exe = env::current_exe().ok();
    helper_search_roots_from(current_dir.as_deref(), current_exe.as_deref())
}

pub(crate) fn helper_search_roots_from(
    current_dir: Option<&Path>,
    current_exe: Option<&Path>,
) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    push_unique_ancestors(current_exe.and_then(Path::parent), &mut roots);
    push_unique_ancestors(current_dir, &mut roots);
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
async fn on_path(cmd: &str) -> bool {
    Command::new("/usr/bin/which")
        .arg(cmd)
        .output()
        .await
        .is_ok_and(|out| out.status.success())
}
