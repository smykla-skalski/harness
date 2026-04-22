use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use crate::agents::assets::{
    AgentAssetTarget, write_agent_target_outputs, write_suite_plugin_outputs,
};
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::{HookAgent, adapter_for};
use crate::infra::io::write_text;
use crate::workspace::dirs_home;

mod install;
mod plugin_cache;
mod registrations;

#[cfg(test)]
mod tests;

pub use install::{choose_install_dir_with_home, install_wrapper};

use install::path_candidates;
use plugin_cache::sync_plugin_cache;
use registrations::{build_codex_config, process_agent_registrations};

/// Shell wrapper script that delegates to the project-local harness binary.
pub const WRAPPER: &str = r#"#!/bin/sh
set -eu

resolve_from_cwd() {
  dir="$(pwd)"
  while :; do
    candidate="${dir}/.claude/plugins/suite/harness"
    if [ -x "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    parent="$(dirname "${dir}")"
    if [ "${parent}" = "${dir}" ]; then
      return 1
    fi
    dir="${parent}"
  done
}

if [ "${CLAUDE_PROJECT_DIR:-}" ]; then
  candidate="${CLAUDE_PROJECT_DIR}/.claude/plugins/suite/harness"
  if [ -x "${candidate}" ]; then
    exec "${candidate}" "$@"
  fi
fi

if candidate="$(resolve_from_cwd)"; then
  exec "${candidate}" "$@"
fi

echo "harness: unable to resolve .claude/plugins/suite/harness" >&2
exit 1
"#;

/// Claude plugin launcher that always resolves the current harness CLI.
pub(crate) const PROJECT_PLUGIN_LAUNCHER: &str =
    include_str!("../../../agents/shared/claude-plugin-harness.sh");

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
    let _ = write_suite_plugin_outputs(project_dir)?;
    let plugin_dir = project_dir.join(".claude").join("plugins").join("suite");
    let plugin_path = plugin_dir.join("harness");

    if !plugin_path.exists() {
        return Err(CliErrorKind::missing_file(format!(
            "missing source wrapper: {}",
            plugin_path.display()
        ))
        .into());
    }

    let (target_dir, _already_on_path) = choose_install_dir_with_home(path_env, home)?;
    install_wrapper(&target_dir)?;

    if plugin_dir.is_dir() {
        sync_plugin_cache(&plugin_dir, home)?;
    }

    Ok(0)
}

/// Generate agent-specific bootstrap files in the project directory.
///
/// # Errors
/// Returns `CliError` on IO or serialization failure.
pub fn write_agent_bootstrap(
    project_dir: &Path,
    agent: HookAgent,
) -> Result<Vec<PathBuf>, CliError> {
    write_process_agent_bootstrap(project_dir, agent)
}

/// Returns whether `harness` resolves from the provided PATH.
#[must_use]
pub fn harness_on_path(path_env: &str) -> bool {
    path_candidates(path_env)
        .iter()
        .any(|dir| dir.join("harness").is_file())
}

fn write_process_agent_bootstrap(
    project_dir: &Path,
    agent: HookAgent,
) -> Result<Vec<PathBuf>, CliError> {
    let mut written = write_agent_target_outputs(project_dir, agent_asset_target(agent))?;
    let existing = written.iter().cloned().collect::<BTreeSet<_>>();
    let planned = planned_agent_bootstrap_files(project_dir, agent);
    for (path, content) in planned {
        if existing.contains(&path) {
            continue;
        }
        write_text(&path, &content)?;
        written.push(path);
    }

    Ok(written)
}

fn agent_asset_target(agent: HookAgent) -> AgentAssetTarget {
    match agent {
        HookAgent::Claude => AgentAssetTarget::Claude,
        HookAgent::Codex => AgentAssetTarget::Codex,
        HookAgent::Gemini => AgentAssetTarget::Gemini,
        HookAgent::Copilot => AgentAssetTarget::Copilot,
        HookAgent::Vibe => AgentAssetTarget::Vibe,
        HookAgent::OpenCode => AgentAssetTarget::OpenCode,
    }
}

pub(crate) fn planned_agent_bootstrap_files(
    project_dir: &Path,
    agent: HookAgent,
) -> Vec<(PathBuf, String)> {
    let path = match agent {
        HookAgent::Claude => project_dir.join(".claude").join("settings.json"),
        HookAgent::Copilot => project_dir
            .join(".github")
            .join("hooks")
            .join("harness.json"),
        HookAgent::Codex => project_dir.join(".codex").join("hooks.json"),
        HookAgent::Gemini => project_dir.join(".gemini").join("settings.json"),
        HookAgent::Vibe => project_dir.join(".vibe").join("hooks.json"),
        HookAgent::OpenCode => project_dir.join(".opencode").join("hooks.json"),
    };
    let registrations = process_agent_registrations(agent);
    let config = adapter_for(agent).generate_config(&registrations);
    let mut planned = vec![(path, config)];
    if agent == HookAgent::Codex {
        planned.push((
            project_dir.join(".codex").join("config.toml"),
            build_codex_config(),
        ));
    }
    planned
}
