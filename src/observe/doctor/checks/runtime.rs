use std::fs;
use std::path::Path;

use crate::feature_flags::RuntimeHookFlags;
use crate::hooks::adapters::HookAgent;
use crate::infra::io::read_json_typed;
use crate::run::context::CurrentRunPointer;
use crate::setup::wrapper::planned_agent_bootstrap_files;
use crate::workspace::compact::{handoff_version, load_latest_compact_handoff};

use super::{DoctorCheck, error_check, ok_check, skipped_check};

pub(super) fn check_runtime_bootstrap_contract(project_dir: &Path) -> Vec<DoctorCheck> {
    let agents = [
        HookAgent::Claude,
        HookAgent::Codex,
        HookAgent::Gemini,
        HookAgent::Copilot,
        HookAgent::Vibe,
        HookAgent::OpenCode,
    ];
    let mut checks = Vec::new();
    let flags = RuntimeHookFlags::from_env();

    for agent in agents {
        for (path, expected) in planned_agent_bootstrap_files(project_dir, agent, &[], flags) {
            let code = runtime_bootstrap_code(agent, &path);
            let summary_name = runtime_bootstrap_label(agent, &path);
            if !path.exists() {
                checks.push(skipped_check(
                    code,
                    "project",
                    format!(
                        "{summary_name} is absent. Runtime drift check skipped for this optional agent install."
                    ),
                    Some(&path),
                    Some(
                        "Run `harness setup bootstrap --project-dir <repo>` for all agents or `harness setup bootstrap --project-dir <repo> --agents <agent>` for a subset.",
                    ),
                ));
                continue;
            }

            match fs::read_to_string(&path) {
                Ok(actual) if actual == expected => checks.push(ok_check(
                    code,
                    "project",
                    format!("{summary_name} matches the current bootstrap contract."),
                    Some(&path),
                )),
                Ok(_) => checks.push(error_check(
                    code,
                    "project",
                    format!("{summary_name} has drifted from the current bootstrap contract."),
                    Some(&path),
                    true,
                    Some(
                        "Run `harness setup bootstrap --project-dir <repo>` for all agents or `harness setup bootstrap --project-dir <repo> --agents <agent>` for a subset.",
                    ),
                )),
                Err(error) => checks.push(error_check(
                    code,
                    "project",
                    format!("{summary_name} cannot be read: {error}"),
                    Some(&path),
                    false,
                    None,
                )),
            }
        }
    }

    checks
}

pub(super) fn check_current_run_pointer(pointer_path: &Path) -> DoctorCheck {
    if !pointer_path.exists() {
        return ok_check(
            "observe_current_run_pointer_absent",
            "pointer",
            "No current run pointer is recorded for this project.",
            Some(pointer_path),
        );
    }

    match read_json_typed::<CurrentRunPointer>(pointer_path) {
        Ok(pointer) => {
            let run_dir = pointer.layout.run_dir();
            if run_dir.is_dir() {
                ok_check(
                    "observe_current_run_pointer",
                    "pointer",
                    format!(
                        "Current run pointer is readable and targets {}.",
                        run_dir.display()
                    ),
                    Some(pointer_path),
                )
            } else {
                error_check(
                    "observe_current_run_pointer_stale",
                    "pointer",
                    format!(
                        "Current run pointer targets a missing run directory: {}.",
                        run_dir.display()
                    ),
                    Some(pointer_path),
                    true,
                    Some("Use `harness run repair` or remove the stale pointer."),
                )
            }
        }
        Err(error) => error_check(
            "observe_current_run_pointer_invalid",
            "pointer",
            format!("Current run pointer is unreadable: {error}"),
            Some(pointer_path),
            true,
            Some("Use `harness run repair` or remove the corrupt pointer."),
        ),
    }
}

pub(super) fn check_compact_handoff(project_dir: &Path, compact_path: &Path) -> DoctorCheck {
    if !compact_path.exists() {
        return ok_check(
            "observe_compact_handoff_absent",
            "compact",
            "No compact handoff is currently recorded for this project.",
            Some(compact_path),
        );
    }

    match load_latest_compact_handoff(project_dir) {
        Ok(Some(handoff)) => {
            if handoff.version != handoff_version() {
                return error_check(
                    "observe_compact_handoff_version",
                    "compact",
                    format!(
                        "Compact handoff uses version {}, expected {}.",
                        handoff.version,
                        handoff_version()
                    ),
                    Some(compact_path),
                    false,
                    Some("Re-run compaction so harness writes a fresh handoff."),
                );
            }
            ok_check(
                "observe_compact_handoff",
                "compact",
                format!(
                    "Compact handoff is readable with status {}.",
                    handoff.status
                ),
                Some(compact_path),
            )
        }
        Ok(None) => ok_check(
            "observe_compact_handoff_absent",
            "compact",
            "No compact handoff is currently recorded for this project.",
            Some(compact_path),
        ),
        Err(error) => error_check(
            "observe_compact_handoff_invalid",
            "compact",
            format!("Compact handoff is unreadable: {error}"),
            Some(compact_path),
            false,
            Some("Delete the stale handoff or regenerate it with a fresh compaction cycle."),
        ),
    }
}

fn runtime_bootstrap_code(agent: HookAgent, path: &Path) -> &'static str {
    match (agent, path.file_name().and_then(|name| name.to_str())) {
        (HookAgent::Claude, Some("settings.json")) => "observe_runtime_claude_settings",
        (HookAgent::Codex, Some("hooks.json")) => "observe_runtime_codex_hooks",
        (HookAgent::Codex, Some("config.toml")) => "observe_runtime_codex_config",
        (HookAgent::Gemini, Some("settings.json")) => "observe_runtime_gemini_settings",
        (HookAgent::Copilot, Some("harness.json")) => "observe_runtime_copilot_hooks",
        (HookAgent::Vibe, Some("hooks.json")) => "observe_runtime_vibe_hooks",
        (HookAgent::OpenCode, Some("hooks.json")) => "observe_runtime_opencode_hooks",
        _ => "observe_runtime_bootstrap",
    }
}

fn runtime_bootstrap_label(agent: HookAgent, path: &Path) -> String {
    let runtime = match agent {
        HookAgent::Claude => "Claude",
        HookAgent::Codex => "Codex",
        HookAgent::Gemini => "Gemini",
        HookAgent::Copilot => "Copilot",
        HookAgent::Vibe => "Vibe",
        HookAgent::OpenCode => "OpenCode",
    };
    let relative = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("runtime config");
    format!("{runtime} bootstrap file `{relative}`")
}
