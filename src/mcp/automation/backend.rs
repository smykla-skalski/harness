use std::env;
use std::path::{Path, PathBuf};

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
    for candidate in default_helper_candidates() {
        if file_exists(&candidate).await {
            return Backend::HarnessInput(candidate);
        }
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

fn default_helper_candidates() -> Vec<PathBuf> {
    // The Node.js server walked up from `dist/automation.js` to the package
    // root, then across to `harness-monitor-registry`. In the Rust CLI we
    // don't have a package-local install path, so we look under the
    // repository sibling `mcp-servers/harness-monitor-registry/.build`.
    let repo_root = repo_root_guess();
    let registry = repo_root.join("mcp-servers/harness-monitor-registry/.build");
    vec![
        registry.join("release/harness-monitor-input"),
        registry.join("debug/harness-monitor-input"),
    ]
}

fn repo_root_guess() -> PathBuf {
    env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
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
