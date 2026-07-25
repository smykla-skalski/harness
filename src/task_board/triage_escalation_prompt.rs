use std::collections::BTreeMap;

use harness_kernel::errors::CliError;

use super::prompt_catalog::{PromptId, render_prompt};
use super::types::TaskBoardItem;

/// Render the escalation prompt for one item from the active prompt catalog,
/// supplying the item facts a template for it may name.
///
/// Embedding `verdict_token` in the prompt means it also travels in the codex
/// run's persisted `prompt` column and its broadcast snapshot, not just this
/// one render. That is accepted: the verdict-report route is never
/// remote-authorizable (see
/// `task_board_triage_escalation_verdict_route_is_never_remote_authorizable`),
/// so the token is useless to anything off-box even if it leaked through one
/// of those surfaces.
///
/// # Errors
/// Returns an error when the configured prompt cannot be rendered for this
/// item, so the caller refuses the spawn instead of starting an agent with a
/// prompt it could not complete.
pub(crate) fn render_triage_escalation_prompt(
    item: &TaskBoardItem,
    escalation_id: &str,
    verdict_token: &str,
    evidence_fingerprint: &str,
) -> Result<String, CliError> {
    let tags = if item.tags.is_empty() {
        "(none)".to_string()
    } else {
        item.tags.join(", ")
    };
    let body = if item.body.trim().is_empty() {
        "(empty)"
    } else {
        item.body.trim()
    };
    let mut variables: BTreeMap<&'static str, String> = BTreeMap::from([
        ("title", item.title.clone()),
        ("priority", format!("{:?}", item.priority)),
        ("kind", format!("{:?}", item.kind)),
        ("tags", tags),
        ("body", body.to_string()),
        ("escalation_id", escalation_id.to_string()),
        ("verdict_token", verdict_token.to_string()),
        ("evidence_fingerprint", evidence_fingerprint.to_string()),
    ]);
    if let Some(project_id) = item.project_id.clone() {
        variables.insert("project_id", project_id);
    }
    render_prompt(PromptId::TriageEscalation, &variables)
}

#[cfg(test)]
#[path = "triage_escalation_prompt_tests.rs"]
mod tests;
