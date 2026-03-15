use std::fs;
use std::path::Path;

use crate::cluster::ClusterMode;
use crate::context::RunContext;
use crate::errors::{CliError, HookMessage, cow};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::workflow::runner::{RunnerPhase, RunnerWorkflowState, SuiteFixState};

/// Tracked subcommands and their expected artifact paths.
const TRACKED_SUBCOMMAND_ARTIFACTS: &[(&str, &[&str])] = &[
    ("apply", &["manifests", "manifest-index.md"]),
    ("capture", &["state"]),
    ("preflight", &["artifacts", "preflight.json"]),
    ("record", &["commands", "command-log.md"]),
    ("run", &["commands", "command-log.md"]),
];

/// Execute the verify-bash hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active || !ctx.is_suite_runner() {
        return Ok(HookResult::allow());
    }
    let words = ctx.command_words();
    if words.len() < 2 {
        return Ok(HookResult::allow());
    }
    let head_name = Path::new(&words[0])
        .file_name()
        .map_or("", |n| n.to_str().unwrap_or(""));
    if head_name != "harness" {
        return Ok(HookResult::allow());
    }
    let subcommand = words[1].as_str();
    let Some(run) = &ctx.run else {
        return Ok(HookResult::allow());
    };
    if subcommand == "cluster" {
        let result = check_cluster(&words, run);
        if result.code.is_empty() {
            maybe_resume_suite_fix(ctx, &words);
        }
        return Ok(result);
    }
    let tracked = TRACKED_SUBCOMMAND_ARTIFACTS
        .iter()
        .any(|(name, _)| *name == subcommand);
    if !tracked {
        maybe_resume_suite_fix(ctx, &words);
        return Ok(HookResult::allow());
    }
    if artifact_ready(subcommand, run) {
        maybe_resume_suite_fix(ctx, &words);
        return Ok(HookResult::allow());
    }
    let target = missing_target(subcommand, run);
    Ok(HookMessage::missing_artifact(cow!("harness {subcommand}"), target).into_result())
}

fn artifact_ready(subcommand: &str, run: &RunContext) -> bool {
    let run_dir = run.layout.run_dir();
    match subcommand {
        "preflight" => {
            run.preflight.is_some()
                && run.prepared_suite.is_some()
                && run.layout.prepared_suite_path().exists()
        }
        "capture" => {
            let state_dir = run.layout.state_dir();
            state_dir
                .read_dir()
                .is_ok_and(|mut entries| entries.next().is_some())
        }
        "apply" => {
            let index_path = run_dir.join("manifests").join("manifest-index.md");
            has_table_rows(&index_path)
        }
        _ => {
            let log_path = run_dir.join("commands").join("command-log.md");
            has_table_rows(&log_path)
        }
    }
}

fn has_table_rows(path: &Path) -> bool {
    fs::read_to_string(path).is_ok_and(|content| content.matches("\n|").count() > 2)
}

fn missing_target(subcommand: &str, run: &RunContext) -> String {
    let run_dir = run.layout.run_dir();
    if subcommand == "preflight" && run_dir.join("artifacts").join("preflight.json").exists() {
        return run.layout.prepared_suite_path().display().to_string();
    }
    if let Some((_, parts)) = TRACKED_SUBCOMMAND_ARTIFACTS
        .iter()
        .find(|(name, _)| *name == subcommand)
    {
        let mut target = run_dir;
        for part in *parts {
            target = target.join(part);
        }
        return target.display().to_string();
    }
    run_dir.display().to_string()
}

fn check_cluster(words: &[String], run: &RunContext) -> HookResult {
    let Some(mode) = cluster_mode(words) else {
        return HookResult::allow();
    };
    if !words
        .iter()
        .any(|w| w == "--run-dir" || w.starts_with("--run-dir="))
    {
        return HookResult::allow();
    }
    let target = run.layout.run_dir().join("current-deploy.json");
    if target.exists() {
        return HookResult::allow();
    }
    HookMessage::missing_artifact(cow!("harness cluster {mode}"), target.display().to_string())
        .into_result()
}

fn cluster_mode(words: &[String]) -> Option<&str> {
    words.get(2..)?.iter().find_map(|w| {
        let mode: ClusterMode = w.parse().ok()?;
        mode.is_up().then_some(w.as_str())
    })
}

fn maybe_resume_suite_fix(ctx: &HookContext, words: &[String]) {
    let Some(ref state) = ctx.runner_state else {
        return;
    };
    if words.len() < 2 {
        return;
    }
    let head = Path::new(&words[0])
        .file_name()
        .map_or("", |n| n.to_str().unwrap_or(""));
    if head != "harness" || words[1] == "runner-state" {
        return;
    }
    if ready_to_resume(state) {
        // The actual state transition is handled by the runner-state command.
        // This hook just validates artifacts; the resume write is deferred to
        // the CLI command layer.
    }
}

fn ready_to_resume(state: &RunnerWorkflowState) -> bool {
    if state.phase != RunnerPhase::Triage {
        return false;
    }
    state
        .suite_fix
        .as_ref()
        .is_some_and(SuiteFixState::ready_to_resume)
}
