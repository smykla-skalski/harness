use std::fs;
use std::path::Path;

use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::HookResult;
use crate::run::context::RunContext;
use harness_kernel::errors::{CliError, HookMessage};
use harness_kernel::kernel::topology::ClusterMode;

/// Parsed harness context: (subcommand, command label, words, run context).
type HarnessAppContext<'a> = (&'a str, String, &'a [String], &'a RunContext);

fn subcommand_artifacts(subcommand: &str) -> Option<&'static [&'static str]> {
    match subcommand {
        "apply" => Some(&["manifests", "manifest-index.md"]),
        "capture" => Some(&["state"]),
        "preflight" => Some(&["artifacts", "preflight.json"]),
        "record" | "run" => Some(&["commands", "command-log.md"]),
        _ => None,
    }
}

/// Execute the verify-bash hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    let Some((subcommand, command_label, words, run)) = extract_harness_context(ctx)? else {
        return Ok(HookResult::allow());
    };
    Ok(verify_artifacts(subcommand, &command_label, words, run))
}

/// Extract the harness subcommand, words, and run context from the hook
/// context. Returns `None` when this hook should allow without further checks.
fn extract_harness_context(ctx: &HookContext) -> Result<Option<HarnessAppContext<'_>>, CliError> {
    if !ctx.skill_active || !ctx.is_suite_runner() {
        return Ok(None);
    }
    let Some(command) = ctx.parsed_command()? else {
        return Ok(None);
    };
    let Some(invocation) = command.first_harness_invocation() else {
        return Ok(None);
    };
    let Some(subcommand) = invocation.subcommand() else {
        return Ok(None);
    };
    let Some(run) = &ctx.run else {
        return Ok(None);
    };
    Ok(Some((
        subcommand,
        invocation.command_label(),
        command.words(),
        run,
    )))
}

fn verify_artifacts(
    subcommand: &str,
    command_label: &str,
    words: &[String],
    run: &RunContext,
) -> HookResult {
    if subcommand == "cluster" {
        return check_cluster(words, run);
    }
    if subcommand_artifacts(subcommand).is_none() || artifact_ready(subcommand, run) {
        return HookResult::allow();
    }
    let target = missing_target(subcommand, run);
    HookMessage::missing_artifact(command_label.to_string(), target).into_result()
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
    if let Some(parts) = subcommand_artifacts(subcommand) {
        let mut target = run_dir;
        for part in parts {
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
    HookMessage::missing_artifact(
        format!("harness setup kuma cluster {mode}"),
        target.display().to_string(),
    )
    .into_result()
}

fn cluster_mode(words: &[String]) -> Option<&str> {
    words.get(2..)?.iter().find_map(|w| {
        let mode: ClusterMode = w.parse().ok()?;
        mode.is_up().then_some(w.as_str())
    })
}

#[cfg(test)]
#[path = "verify_bash/tests.rs"]
mod tests;
