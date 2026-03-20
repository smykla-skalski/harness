use std::path::{Path, PathBuf};

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
use registrations::{build_codex_config, build_opencode_bridge, process_agent_registrations};

/// Shell wrapper script that delegates to the project-local harness binary.
pub const WRAPPER: &str = r#"#!/bin/sh
set -eu

if [ "${CLAUDE_PROJECT_DIR:-}" ]; then
  candidate="${CLAUDE_PROJECT_DIR}/.claude/plugins/suite/harness"
  if [ -x "${candidate}" ]; then
    exec "${candidate}" "$@"
  fi
fi

if command -v git >/dev/null 2>&1; then
  if repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    candidate="${repo_root}/.claude/plugins/suite/harness"
    if [ -x "${candidate}" ]; then
      exec "${candidate}" "$@"
    fi
  fi
fi

echo "harness: unable to resolve .claude/plugins/suite/harness" >&2
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
pub fn main_with_home(project_dir: &Path, path_env: &str, home: &Path) -> Result<i32, CliError> {
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
    match agent {
        HookAgent::ClaudeCode | HookAgent::GeminiCli | HookAgent::Codex => {
            write_process_agent_bootstrap(project_dir, agent)
        }
        HookAgent::OpenCode => write_opencode_bootstrap(project_dir),
    }
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
    let path = match agent {
        HookAgent::ClaudeCode => project_dir.join(".claude").join("settings.json"),
        HookAgent::GeminiCli => project_dir.join(".gemini").join("settings.json"),
        HookAgent::Codex => project_dir.join(".codex").join("hooks.json"),
        HookAgent::OpenCode => unreachable!("handled separately"),
    };
    let registrations = process_agent_registrations(agent);
    let config = adapter_for(agent).generate_config(&registrations);
    write_text(&path, &config)?;

    let mut written = vec![path];
    if agent == HookAgent::Codex {
        let config_path = project_dir.join(".codex").join("config.toml");
        write_text(&config_path, &build_codex_config())?;
        written.push(config_path);
    }

    Ok(written)
}

fn write_opencode_bootstrap(project_dir: &Path) -> Result<Vec<PathBuf>, CliError> {
    let plugin_path = project_dir
        .join(".opencode")
        .join("plugins")
        .join("harness-bridge.ts");
    let package_path = project_dir.join(".opencode").join("package.json");

    write_text(&plugin_path, &build_opencode_bridge()?)?;
    if !package_path.exists() {
        write_text(
            &package_path,
            "{\n  \"name\": \"harness-opencode\",\n  \"private\": true,\n  \"type\": \"module\"\n}\n",
        )?;
    }

    Ok(vec![plugin_path, package_path])
}
