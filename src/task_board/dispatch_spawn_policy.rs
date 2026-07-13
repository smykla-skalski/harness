//! Spawn-agent policy decision for dispatch: subject enrichment, fail-closed
//! switches, kill switch, and the graph/built-in gate selection. Split out of
//! `dispatch.rs` to keep each file under the source-length cap.

#[cfg(test)]
use std::path::Path;

use crate::task_board::policy::{
    BuiltInPolicyGate, POLICY_VERSION, PolicyAction, PolicyApprovalGrant, PolicyApprovalGrantState,
    PolicyApprovalState, PolicyDecision, PolicyGate, PolicyInput, PolicyReasonCode, PolicySubject,
};
#[cfg(test)]
use crate::task_board::policy_graph::resolve_gate_policy;
use crate::task_board::policy_graph::{
    PolicyCanvasWorkspace, PolicyGraph, PolicyPendingGrantRequest, PolicyPipelineMode,
    RecordedPolicyDecision, record_pending_grant, record_policy_decision,
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

impl SpawnGateSwitches {
    /// Read the persisted spawn switches off a policy workspace.
    #[must_use]
    pub fn from_workspace(workspace: &PolicyCanvasWorkspace) -> Self {
        Self {
            requires_live_policy: workspace.spawn_requires_live_policy,
            kill_switch: workspace.spawn_kill_switch,
        }
    }
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
    grant: Option<&PolicyApprovalGrant>,
) -> (PolicyDecision, Option<String>) {
    let mut input = spawn_policy_input(item, evaluated_at);
    if let Some(grant) = grant {
        input.approvals.push(PolicyApprovalGrantState {
            node_id: grant.node_id.clone(),
            state: grant.state,
        });
    }
    if switches.kill_switch {
        return deny_kill_switch(&item.id, input);
    }
    if let Some((canvas_id, document)) = policy
        && document.mode != PolicyPipelineMode::Draft
    {
        return graph_decision(&item.id, canvas_id, document, input);
    }
    if switches.requires_live_policy {
        return deny_requires_live_policy(&item.id, input);
    }
    (BuiltInPolicyGate::default().evaluate(&input), None)
}

/// The durable grant this dispatch consumes: only an approved live grant whose
/// gate the decision cleared. Everything else leaves nothing to consume.
pub(super) fn consumed_grant_id(
    grant: Option<&PolicyApprovalGrant>,
    decision: &PolicyDecision,
) -> Option<String> {
    grant
        .filter(|grant| grant.state == PolicyApprovalState::Approved && decision.is_allow())
        .map(|grant| grant.id.clone())
}

/// Evaluate the live graph, record the decision, emit pending-grant requests for
/// any reached approval gate, and return the decision with its recorded id.
fn graph_decision(
    board_item_id: &str,
    canvas_id: &str,
    document: &PolicyGraph,
    input: PolicyInput,
) -> (PolicyDecision, Option<String>) {
    let simulation = document.simulate(&input);
    for request in &simulation.approval_requests {
        record_pending_grant(PolicyPendingGrantRequest {
            board_item_id: board_item_id.to_owned(),
            action: input.action,
            canvas_id: Some(canvas_id.to_owned()),
            canvas_revision: document.revision,
            node_id: request.node_id.clone(),
            reason_code: request.reason_code,
            expiry_seconds: request.expiry_seconds,
        });
    }
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
    (decision, Some(decision_id))
}

fn deny_kill_switch(board_item_id: &str, input: PolicyInput) -> (PolicyDecision, Option<String>) {
    warn_kill_switch(board_item_id);
    record_spawn_switch_deny(input, PolicyReasonCode::SpawnKillSwitchEngaged)
}

fn deny_requires_live_policy(
    board_item_id: &str,
    input: PolicyInput,
) -> (PolicyDecision, Option<String>) {
    info_requires_live_policy(board_item_id);
    record_spawn_switch_deny(input, PolicyReasonCode::SpawnPolicyRequired)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing::warn! macro expands into a chain clippy reads as branchy"
)]
fn warn_kill_switch(board_item_id: &str) {
    tracing::warn!(
        target: "harness::task_board",
        board_item_id = %board_item_id,
        "spawn kill switch engaged; denying spawn dispatch",
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing::info! macro expands into a chain clippy reads as branchy"
)]
fn info_requires_live_policy(board_item_id: &str) {
    tracing::info!(
        target: "harness::task_board",
        board_item_id = %board_item_id,
        "spawn requires a live enforced policy but none is active; denying",
    );
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
        policy_version: POLICY_VERSION.to_string(),
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
