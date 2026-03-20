use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::guard_bash::predicates::{deny_runner_flow, is_run_scope_flag};
use crate::hooks::protocol::hook_result::HookResult;
use crate::kernel::command_intent::{
    semantic_harness_subcommand, semantic_harness_tail, significant_words,
};
use crate::run::workflow::{RunnerPhase, RunnerWorkflowState};

#[must_use]
pub(crate) fn has_tracked_run_context(ctx: &HookContext) -> bool {
    ctx.run.is_some() || ctx.runner_state.is_some() || ctx.effective_run_dir().is_some()
}

pub(crate) fn guard_runner_phase(ctx: &HookContext, words: &[String]) -> HookResult {
    if let Some(ref run) = ctx.run
        && let Some(reason) = completed_run_reuse_reason(words)
        && let Some(ref status) = run.status
        && status.overall_verdict.is_finalized()
    {
        return deny_runner_flow(&format!(
            "{reason}. Start a new run with \
             `harness run init --run-id <new-run-id> ...` first"
        ));
    }
    if let Some(ref state) = ctx.runner_state {
        let (allowed, reason) = allowed_command(state, words);
        if !allowed {
            return deny_runner_flow(reason.unwrap_or("runner state does not allow this command"));
        }
    }
    HookResult::allow()
}

fn completed_run_reuse_reason(words: &[String]) -> Option<&'static str> {
    if has_explicit_run_scope(words) {
        return None;
    }
    let sig = significant_words(words);
    let semantic = semantic_harness_tail(&sig)?;
    let subcommand = semantic_harness_subcommand(&sig)?;
    completed_run_reuse_for_subcommand(subcommand, semantic)
}

fn completed_run_reuse_for_subcommand(
    subcommand: &str,
    significant: &[&str],
) -> Option<&'static str> {
    match subcommand {
        "cluster" if cluster_mode_is_teardown(significant) => None,
        "cluster" => Some(
            "the active run is already final; do not start or \
             redeploy clusters on it",
        ),
        "report" if significant.len() >= 2 && significant[1] == "check" => None,
        "report" => Some("the active run is already final; do not mutate the finalized report"),
        "runner-state"
            if significant
                .iter()
                .any(|w| *w == "--event" || w.starts_with("--event=")) =>
        {
            Some("the active run is already final; do not reopen or advance it")
        }
        "apply" | "bootstrap" | "capture" | "cli" | "diff" | "envoy" | "gateway" | "preflight"
        | "record" | "run" | "validate" => Some(
            "the active run is already final; start a new run before \
             continuing bootstrap or execution",
        ),
        _ => None,
    }
}

fn cluster_mode_is_teardown(significant: &[&str]) -> bool {
    significant
        .get(1)
        .is_some_and(|mode| mode.ends_with("-down"))
}

fn has_explicit_run_scope(words: &[String]) -> bool {
    let sig = significant_words(words);
    sig.iter().any(|word| is_run_scope_flag(word))
}

fn allowed_command(state: &RunnerWorkflowState, words: &[String]) -> (bool, Option<&'static str>) {
    let sig = significant_words(words);
    let Some(subcommand) = semantic_harness_subcommand(&sig) else {
        return (true, None);
    };
    match state.phase() {
        RunnerPhase::Completed | RunnerPhase::Aborted => match subcommand {
            "closeout" | "runner-state" | "report" | "session-stop" => (true, None),
            _ => (
                false,
                Some("the run has reached a final state; only closeout commands are allowed"),
            ),
        },
        RunnerPhase::Triage => {
            if matches!(subcommand, "runner-state" | "report" | "closeout") {
                return (true, None);
            }
            if state.suite_fix().is_some() {
                return (true, None);
            }
            (true, None)
        }
        _ => (true, None),
    }
}
