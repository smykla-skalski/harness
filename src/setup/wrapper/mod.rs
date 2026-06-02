use std::path::{Path, PathBuf};

use fs_err;

use tracing::info;

use crate::errors::{CliError, CliErrorKind};
use crate::feature_flags::{RuntimeHookFlags, SUITE_HOOKS_ENV};
use crate::hooks::adapters::{HookAgent, adapter_for};
use crate::infra::io::write_text;
use crate::workspace::dirs_home;

mod install;
mod registrations;

#[cfg(test)]
mod tests;

pub use install::{choose_install_dir_with_home, install_wrapper};

use install::path_candidates;
use registrations::process_agent_registrations;

/// Shell wrapper script that delegates to the project-local harness binary.
pub const WRAPPER: &str = r#"#!/bin/sh
set -eu

is_repo_root() {
  [ -f "$1/Cargo.toml" ] && [ -f "$1/scripts/cargo-local.sh" ]
}

resolve_from_cwd() {
  dir="$1"
  while :; do
    if is_repo_root "${dir}"; then
      printf '%s\n' "${dir}"
      return 0
    fi
    parent="$(dirname "${dir}")"
    if [ "${parent}" = "${dir}" ]; then
      return 1
    fi
    dir="${parent}"
  done
}

resolve_repo_root() {
 if [ "${CLAUDE_PROJECT_DIR:-}" ]; then
   if root="$(resolve_from_cwd "${CLAUDE_PROJECT_DIR}")"; then
     printf '%s\n' "${root}"
     return 0
   fi
 fi
 resolve_from_cwd "$(pwd)"
}

repo_version() {
 command awk '
   $0 == "[package]" { in_package = 1; next }
   /^\[/ { if (in_package) exit }
   in_package && $1 == "version" {
     gsub(/"/, "", $3)
     print $3
     exit
   }
 ' "$1/Cargo.toml"
}

binary_version() {
 "$1" --version 2>/dev/null | command awk 'NR == 1 { print $2 }'
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
current="${script_dir}/$(basename -- "$0")"
repo_root="$(resolve_repo_root || true)"

if [ -n "${repo_root}" ] && [ -x "${repo_root}/target/debug/harness" ]; then
 exec "${repo_root}/target/debug/harness" "$@"
fi

if command -v harness >/dev/null 2>&1; then
 candidate="$(command -v harness)"
 candidate_dir=$(CDPATH='' cd -- "$(dirname -- "${candidate}")" && pwd)
 candidate_path="${candidate_dir}/$(basename -- "${candidate}")"
 if [ "${candidate_path}" != "${current}" ]; then
   if [ -z "${repo_root}" ]; then
     exec "${candidate_path}" "$@"
   fi

   expected_version="$(repo_version "${repo_root}")"
   actual_version="$(binary_version "${candidate_path}")"
   if [ -n "${expected_version}" ] && [ "${actual_version}" = "${expected_version}" ]; then
     exec "${candidate_path}" "$@"
   fi

   echo "harness: refusing to use ${candidate_path} because version ${actual_version:-unknown} does not match repo version ${expected_version:-unknown}; run \`mise run install\` or build target/debug/harness" >&2
   exit 1
 fi
fi

if [ -n "${repo_root}" ]; then
 echo "harness: unable to resolve a current harness binary for ${repo_root}" >&2
else
 echo "harness: unable to resolve a harness repo from \$CLAUDE_PROJECT_DIR or \$PWD" >&2
fi
exit 1
"#;

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
pub fn main_with_home(_project_dir: &Path, path_env: &str, home: &Path) -> Result<i32, CliError> {
    let (target_dir, _already_on_path) = choose_install_dir_with_home(path_env, home)?;
    install_wrapper(&target_dir)?;
    Ok(0)
}

/// Generate agent-specific bootstrap files in the project directory.
///
/// # Errors
/// Returns `CliError` on IO or serialization failure.
pub fn write_agent_bootstrap(
    project_dir: &Path,
    agent: HookAgent,
    skip_runtime_hooks: &[HookAgent],
    flags: RuntimeHookFlags,
) -> Result<Vec<PathBuf>, CliError> {
    write_process_agent_bootstrap(project_dir, agent, skip_runtime_hooks, flags)
}

/// Returns whether `harness` resolves from the provided PATH.
#[must_use]
pub fn harness_on_path(path_env: &str) -> bool {
    path_candidates(path_env)
        .iter()
        .any(|dir| is_executable_file(&dir.join("harness")))
}

fn is_executable_file(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(metadata) = fs_err::metadata(path) {
            let mode = metadata.permissions().mode();
            return metadata.is_file() && (mode & 0o111) != 0;
        }
        false
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

fn write_process_agent_bootstrap(
    project_dir: &Path,
    agent: HookAgent,
    skip_runtime_hooks: &[HookAgent],
    flags: RuntimeHookFlags,
) -> Result<Vec<PathBuf>, CliError> {
    let mut written = Vec::new();
    remove_skipped_runtime_hook_config(project_dir, agent, skip_runtime_hooks)?;
    let planned = planned_agent_bootstrap_files(project_dir, agent, skip_runtime_hooks, flags);
    for (path, content) in planned {
        write_text(&path, &content)?;
        written.push(path);
    }

    Ok(written)
}

fn remove_skipped_runtime_hook_config(
    project_dir: &Path,
    agent: HookAgent,
    skip_runtime_hooks: &[HookAgent],
) -> Result<(), CliError> {
    if !skip_runtime_hooks.contains(&agent) {
        return Ok(());
    }
    let Some(path) = runtime_config_path(project_dir, agent) else {
        return Ok(());
    };
    if path.is_file() {
        fs_err::remove_file(&path)
            .map_err(|error| CliError::from(CliErrorKind::workflow_io(error.to_string())))?;
    }
    Ok(())
}

fn log_omitted_hook_families(path: &Path, flags: RuntimeHookFlags) {
    log_suite_hook_omission(path, flags.suite_hooks);
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_suite_hook_omission(path: &Path, enabled: bool) {
    if enabled {
        return;
    }
    info!(
        config = %path.display(),
        "regenerated runtime config: suite-lifecycle hooks omitted (guard-stop / context-agent / validate-agent / tool-failure); set {SUITE_HOOKS_ENV}=1 or pass --enable-suite-hooks to restore",
    );
}

pub(crate) fn planned_agent_bootstrap_files(
    project_dir: &Path,
    agent: HookAgent,
    skip_runtime_hooks: &[HookAgent],
    flags: RuntimeHookFlags,
) -> Vec<(PathBuf, String)> {
    let mut planned = Vec::new();
    if !skip_runtime_hooks.contains(&agent) {
        let path = runtime_config_path(project_dir, agent);
        if let Some(path) = path {
            let registrations = process_agent_registrations(agent, flags);
            let config = adapter_for(agent).generate_config(&registrations);
            log_omitted_hook_families(&path, flags);
            planned.push((path, config));
        }
    }
    planned
}

fn runtime_config_path(project_dir: &Path, agent: HookAgent) -> Option<PathBuf> {
    match agent {
        HookAgent::Claude => Some(project_dir.join(".claude").join("settings.json")),
        HookAgent::Copilot => Some(
            project_dir
                .join(".github")
                .join("hooks")
                .join("harness.json"),
        ),
        HookAgent::Codex => None,
        HookAgent::Gemini => Some(project_dir.join(".gemini").join("settings.json")),
        HookAgent::Vibe => Some(project_dir.join(".vibe").join("hooks.json")),
        HookAgent::OpenCode => Some(project_dir.join(".opencode").join("hooks.json")),
    }
}
