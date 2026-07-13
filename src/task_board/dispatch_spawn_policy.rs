//! Spawn-agent policy decision for dispatch: subject enrichment, fail-closed
//! switches, kill switch, and the graph/built-in gate selection. Split out of
//! `dispatch.rs` to keep each file under the source-length cap.

#[cfg(test)]
use std::path::Path;

use crate::task_board::policy::{
    BuiltInPolicyGate, PolicyAction, PolicyDecision, PolicyGate, PolicyInput, PolicyReasonCode,
    PolicySubject,
};
#[cfg(test)]
use crate::task_board::policy_graph::resolve_gate_policy;
use crate::task_board::policy_graph::{
    PolicyGraph, PolicyPipelineMode, RecordedPolicyDecision, record_policy_decision,
};
use crate::task_board::types::TaskBoardItem;

/// Persisted spawn switches that gate the dispatch decision fail-closed,
/// independently of the authored graph. Resolved from the policy workspace by
/// the caller.
#[derive(Debug, Clone, Copy, Default)]
pub struct SpawnGateSwitches {
    /// Deny spawning when no active live enforced graph exists instead of
    /// falling back to the built-in allow gate.
    pub requires_live_policy: bool,
    /// Emergency kill switch: deny all spawning before graph evaluation.
    pub kill_switch: bool,
}

/// Build the `spawn_agent` policy input for a board item. Fills the WP3
/// enrichment (tags, priority, agent mode, target project types) so the recorded
/// decision can explain the gate result and future subject-match blocks can route
/// on it. `evaluated_at` is the caller-supplied evaluation timestamp: dispatch
/// passes `now`; simulation/replay pass scenario-supplied or recorded values so
/// those paths stay deterministic.
pub(crate) fn spawn_policy_input(
    item: &TaskBoardItem,
    evaluated_at: Option<String>,
) -> PolicyInput {
    let mut input = PolicyInput::new(PolicyAction::SpawnAgent);
    input.evaluated_at = evaluated_at;
    input.subject = PolicySubject {
        task_board_item_id: Some(item.id.clone()),
        session_id: item.session_id.clone(),
        repository: item.project_id.clone(),
        tags: item.tags.clone(),
        priority: Some(item.priority),
        agent_mode: Some(item.agent_mode),
        target_project_types: item.target_project_types.clone(),
        ..PolicySubject::default()
    };
    input
}

#[cfg(test)]
pub(super) fn dispatch_policy(
    item: &TaskBoardItem,
    policy_root: &Path,
) -> (PolicyDecision, Option<String>) {
    let input = spawn_policy_input(item, None);
    if let Some(document) = resolve_gate_policy(policy_root)
        && document.mode != PolicyPipelineMode::Draft
    {
        let simulation = document.simulate(&input);
        let decision = simulation.decision;
        let record = RecordedPolicyDecision::new(
            document.revision,
            input,
            decision.clone(),
            simulation.visited_node_ids,
            "task_board_dispatch",
        )
        .with_canvas_id(document.canvas_id.clone());
        let decision_id = record.id.clone();
        record_policy_decision(record);
        return (decision, Some(decision_id));
    }
    (BuiltInPolicyGate::default().evaluate(&input), None)
}

pub(super) fn dispatch_policy_from_graph(
    item: &TaskBoardItem,
    policy: Option<(&str, &PolicyGraph)>,
    evaluated_at: Option<String>,
    switches: SpawnGateSwitches,
) -> (PolicyDecision, Option<String>) {
    let input = spawn_policy_input(item, evaluated_at);
    if switches.kill_switch {
        tracing::warn!(
            target: "harness::task_board",
            board_item_id = %item.id,
            "spawn kill switch engaged; denying spawn dispatch",
        );
        return record_spawn_switch_deny(input, PolicyReasonCode::SpawnKillSwitchEngaged);
    }
    if let Some((canvas_id, document)) = policy
        && document.mode != PolicyPipelineMode::Draft
    {
        let simulation = document.simulate(&input);
        let decision = simulation.decision;
        let record = RecordedPolicyDecision::new(
            document.revision,
            input,
            decision.clone(),
            simulation.visited_node_ids,
            "task_board_dispatch",
        )
        .with_canvas_id(Some(canvas_id.to_string()));
        let decision_id = record.id.clone();
        record_policy_decision(record);
        return (decision, Some(decision_id));
    }
    if switches.requires_live_policy {
        tracing::info!(
            target: "harness::task_board",
            board_item_id = %item.id,
            "spawn requires a live enforced policy but none is active; denying",
        );
        return record_spawn_switch_deny(input, PolicyReasonCode::SpawnPolicyRequired);
    }
    (BuiltInPolicyGate::default().evaluate(&input), None)
}

/// Build and record a fail-closed spawn `Deny`, returning the decision and its
/// recorded id. The decision carries no canvas/revision because no live graph
/// produced it.
fn record_spawn_switch_deny(
    input: PolicyInput,
    reason_code: PolicyReasonCode,
) -> (PolicyDecision, Option<String>) {
    let decision = PolicyDecision::Deny {
        reason_code,
        policy_version: crate::task_board::policy::POLICY_VERSION.to_string(),
    };
    let record = RecordedPolicyDecision::new(
        0,
        input,
        decision.clone(),
        Vec::new(),
        "task_board_dispatch_switch",
    );
    let decision_id = record.id.clone();
    record_policy_decision(record);
    (decision, Some(decision_id))
}
