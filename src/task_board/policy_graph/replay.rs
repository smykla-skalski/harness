//! Replay the current draft policy against the recorded real-decision feed.
//!
//! Phase 1 captures every enforced evaluation into `policy_decisions`. Replay
//! reads the last N real inputs recorded for the canvas under review (plus
//! legacy rows with no recorded provenance), re-simulates the current draft in
//! dry-run mode against each, and reports where the draft would now decide
//! differently than history actually did. This answers "if I make this draft
//! live, what changes for the traffic I have already seen?".
//!
//! A draft that re-simulates to `MissingMergeEvidence` for a historical input is
//! reported as a distinct insufficient-evidence state rather than a false
//! "changed": the recorded input simply did not carry the evidence the draft now
//! needs to judge, so the comparison is not meaningful.

use serde::{Deserialize, Serialize};

use crate::errors::CliError;

use super::decisions::RecordedPolicyDecision;
use super::store::active_canvas_for_request;
use super::{
    PolicyAction, PolicyCanvasWorkspace, PolicyDecision, PolicyGraphMode, PolicyReasonCode,
};

/// One replayed decision: what history recorded versus what the draft decides
/// now for the same input.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyPipelineReplayDecision {
    pub id: String,
    pub recorded_at: String,
    pub action: PolicyAction,
    pub historical_decision: PolicyDecision,
    pub draft_decision: PolicyDecision,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub visited_node_ids: Vec<String>,
    pub changed: bool,
    pub insufficient_evidence: bool,
}

/// The result of replaying the draft against a window of recorded decisions.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyPipelineReplayResult {
    pub sample_size: usize,
    pub changed_count: usize,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub decisions: Vec<PolicyPipelineReplayDecision>,
}

/// Replay `recorded` decisions against the active draft, newest first.
///
/// Each recorded input is re-simulated through the draft in dry-run mode. A row
/// is `changed` when the draft decides differently than history and the draft
/// could actually judge the input; a draft `MissingMergeEvidence` outcome is
/// flagged `insufficient_evidence` and never counted as changed.
///
/// # Errors
/// Returns `CliError` when the active canvas cannot be resolved or a stale
/// `expected_canvas_id` no longer matches the active selection.
pub fn apply_replay(
    ws: &PolicyCanvasWorkspace,
    recorded: &[RecordedPolicyDecision],
    expected_canvas_id: Option<&str>,
) -> Result<PolicyPipelineReplayResult, CliError> {
    let draft = active_canvas_for_request(ws, expected_canvas_id)?
        .document
        .clone()
        .with_mode(PolicyGraphMode::DryRun);
    let decisions: Vec<_> = recorded
        .iter()
        .map(|record| {
            let simulation = draft.simulate(&record.input);
            let draft_decision = simulation.decision;
            let insufficient_evidence =
                reason_code(&draft_decision) == PolicyReasonCode::MissingMergeEvidence;
            let changed = !insufficient_evidence && record.decision != draft_decision;
            PolicyPipelineReplayDecision {
                id: record.id.clone(),
                recorded_at: record.recorded_at.clone(),
                action: record.input.action,
                historical_decision: record.decision.clone(),
                draft_decision,
                visited_node_ids: simulation.visited_node_ids,
                changed,
                insufficient_evidence,
            }
        })
        .collect();
    let changed_count = decisions.iter().filter(|decision| decision.changed).count();
    Ok(PolicyPipelineReplayResult {
        sample_size: decisions.len(),
        changed_count,
        decisions,
    })
}

/// The reason code carried by any decision variant.
const fn reason_code(decision: &PolicyDecision) -> PolicyReasonCode {
    match decision {
        PolicyDecision::Allow { reason_code, .. }
        | PolicyDecision::Deny { reason_code, .. }
        | PolicyDecision::RequireHuman { reason_code, .. }
        | PolicyDecision::RequireConsensus { reason_code, .. }
        | PolicyDecision::DryRunOnly { reason_code, .. } => *reason_code,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::PolicyInput;
    use crate::task_board::policy::POLICY_VERSION;

    fn record(input: PolicyInput, decision: PolicyDecision) -> RecordedPolicyDecision {
        RecordedPolicyDecision::new(1, input, decision, vec![], "test")
    }

    fn deny() -> PolicyDecision {
        PolicyDecision::Deny {
            reason_code: PolicyReasonCode::ChecksNotGreen,
            policy_version: POLICY_VERSION.to_owned(),
        }
    }

    #[test]
    fn empty_feed_replays_to_an_empty_result() {
        let ws = PolicyCanvasWorkspace::seeded();
        let result = apply_replay(&ws, &[], None).expect("replay");
        assert_eq!(result.sample_size, 0);
        assert_eq!(result.changed_count, 0);
        assert!(result.decisions.is_empty());
    }

    #[test]
    fn replay_flags_only_decisions_that_differ_from_the_draft() {
        let ws = PolicyCanvasWorkspace::seeded();
        let draft = ws
            .active_canvas()
            .expect("active canvas")
            .document
            .clone()
            .with_mode(PolicyGraphMode::DryRun);
        // Sync resolves to a stable allow that does not need merge evidence.
        let input = PolicyInput::new(PolicyAction::Sync);
        let draft_decision = draft.simulate(&input).decision;
        assert_ne!(draft_decision, deny(), "fixture: sync must not deny");

        let unchanged = record(input.clone(), draft_decision);
        let changed = record(input, deny());
        let result = apply_replay(&ws, &[unchanged, changed], None).expect("replay");

        assert_eq!(result.sample_size, 2);
        assert_eq!(result.changed_count, 1);
        let unchanged_row = result.decisions.iter().find(|row| !row.changed).unwrap();
        assert!(!unchanged_row.insufficient_evidence);
        let changed_row = result.decisions.iter().find(|row| row.changed).unwrap();
        assert!(!changed_row.insufficient_evidence);
        assert_eq!(changed_row.historical_decision, deny());
    }

    #[test]
    fn replay_marks_missing_evidence_as_insufficient_not_changed() {
        let ws = PolicyCanvasWorkspace::seeded();
        let draft = ws
            .active_canvas()
            .expect("active canvas")
            .document
            .clone()
            .with_mode(PolicyGraphMode::DryRun);
        // A merge with no evidence cannot be judged by the draft.
        let input = PolicyInput::new(PolicyAction::MergePr);
        let draft_decision = draft.simulate(&input).decision;
        assert_eq!(
            reason_code(&draft_decision),
            PolicyReasonCode::MissingMergeEvidence,
            "fixture: evidence-less merge must require evidence"
        );

        // History recorded a real allow, but replay must not call this "changed".
        let historical = PolicyDecision::Allow {
            reason_code: PolicyReasonCode::AutoMergeAllowed,
            policy_version: POLICY_VERSION.to_owned(),
        };
        let result = apply_replay(&ws, &[record(input, historical)], None).expect("replay");

        assert_eq!(result.sample_size, 1);
        assert_eq!(result.changed_count, 0);
        assert!(result.decisions[0].insufficient_evidence);
        assert!(!result.decisions[0].changed);
    }
}
