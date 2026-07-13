use std::collections::{HashSet, VecDeque};

use tracing::warn;

mod decisions;

use super::{
    PORT_APPROVED, PORT_DEFAULT, PolicyApprovalRequest, PolicyDecision, PolicyEvidenceCheck,
    PolicyEvidenceField, PolicyEvidencePredicate, PolicyGraph, PolicyGraphDecision,
    PolicyGraphEdgeCondition, PolicyGraphNode, PolicyGraphNodeId, PolicyGraphNodeKind,
    PolicyIfThenElseCondition, PolicyReasonCode, PolicyRuntimeBoundary, PolicySwitchArm,
    PolicySwitchNode,
};
use crate::task_board::policy::{PolicyAction, PolicyApprovalState, PolicyInput};

use decisions::{
    dry_run_only, require_consensus, require_human, supervisor_decision, supervisor_reason_code,
};

/// Side-effect signals collected while the pure evaluator walks the graph: the
/// runtime wait boundaries and the pending-grant requests emitted by approval
/// gates that had no existing grant.
#[derive(Default)]
struct EvaluationEffects {
    boundaries: Vec<PolicyRuntimeBoundary>,
    approval_requests: Vec<PolicyApprovalRequest>,
}

enum EvaluationStep {
    Continue(Vec<String>),
    Terminal(PolicyDecision),
}

/// A completed graph evaluation: the decision, the visited node ids, the runtime
/// wait boundaries, and the pending-grant requests emitted by approval gates.
type EvaluationOutcome = (
    PolicyDecision,
    Vec<String>,
    Vec<PolicyRuntimeBoundary>,
    Vec<PolicyApprovalRequest>,
);

impl PolicyGraph {
    pub(super) fn evaluate_graph(&self, input: &PolicyInput) -> Option<EvaluationOutcome> {
        if !self.validate().is_valid() {
            return Some((
                require_human(PolicyReasonCode::HumanRequired),
                Vec::new(),
                Vec::new(),
                Vec::new(),
            ));
        }
        let mut pending = VecDeque::from([self.entry_node(input)?.id.clone()]);
        let mut visited = Vec::new();
        let mut visited_ids: HashSet<String> = HashSet::new();
        let mut effects = EvaluationEffects::default();
        let safety_cap = self.nodes.len().saturating_mul(4).max(4);
        while let Some(node_id) = pending.pop_front() {
            if visited_ids.contains(node_id.as_str()) {
                continue;
            }
            if let Some(bailout) =
                Self::traversal_bailout(node_id.as_str(), &visited, &mut visited_ids, safety_cap)
            {
                return Some((
                    bailout.0,
                    bailout.1,
                    effects.boundaries,
                    effects.approval_requests,
                ));
            }
            let node = self
                .nodes
                .iter()
                .find(|candidate| candidate.id == node_id)?;
            visited.push(node.id.as_str().to_owned());
            match self.evaluation_step(node, input, &mut effects) {
                EvaluationStep::Continue(next_node_ids) => {
                    pending.extend(next_node_ids.into_iter().map(PolicyGraphNodeId::from));
                }
                EvaluationStep::Terminal(decision) => {
                    return Some((
                        decision,
                        visited,
                        effects.boundaries,
                        effects.approval_requests,
                    ));
                }
            }
        }
        Some((
            supervisor_decision(PolicyGraphDecision::Allow, PolicyReasonCode::DefaultAllow),
            visited,
            effects.boundaries,
            effects.approval_requests,
        ))
    }

    fn traversal_bailout(
        node_id: &str,
        visited: &[String],
        visited_ids: &mut HashSet<String>,
        safety_cap: usize,
    ) -> Option<(PolicyDecision, Vec<String>)> {
        if !visited_ids.insert(node_id.to_owned()) {
            warn_cycle(visited, node_id);
            return Some((
                require_human(PolicyReasonCode::HumanRequired),
                visited.to_vec(),
            ));
        }
        if visited.len() >= safety_cap {
            warn_safety_cap(visited, safety_cap);
            return Some((
                require_human(PolicyReasonCode::HumanRequired),
                visited.to_vec(),
            ));
        }
        None
    }

    fn evaluation_step(
        &self,
        node: &PolicyGraphNode,
        input: &PolicyInput,
        effects: &mut EvaluationEffects,
    ) -> EvaluationStep {
        match &node.kind {
            PolicyGraphNodeKind::Trigger { .. }
            | PolicyGraphNodeKind::WorkflowEntry(_)
            | PolicyGraphNodeKind::ActionStep(_)
            | PolicyGraphNodeKind::ReviewScreenshotPaste
            | PolicyGraphNodeKind::OcrImage
            | PolicyGraphNodeKind::ResolveReviewPullRequests
            | PolicyGraphNodeKind::EventWait(_)
            | PolicyGraphNodeKind::Handoff(_) => EvaluationStep::Continue(
                self.next_node(node.id.as_str(), &PolicyGraphEdgeCondition::Always)
                    .into_iter()
                    .collect(),
            ),
            PolicyGraphNodeKind::CopyReviewPullRequestList => {
                EvaluationStep::Terminal(require_human(PolicyReasonCode::HumanRequired))
            }
            PolicyGraphNodeKind::WaitStep(step) => {
                effects.boundaries.push(PolicyRuntimeBoundary {
                    node_id: node.id.as_str().to_owned(),
                    resume_key: step.resume_key.clone(),
                    wait: step.wait.clone(),
                });
                EvaluationStep::Continue(
                    self.next_node(node.id.as_str(), &PolicyGraphEdgeCondition::Always)
                        .into_iter()
                        .collect(),
                )
            }
            PolicyGraphNodeKind::ActionGate { .. } => EvaluationStep::Continue(
                self.next_node_for_action(node.id.as_str(), input.action)
                    .into_iter()
                    .collect(),
            ),
            PolicyGraphNodeKind::EvidenceCheck { checks } => {
                let condition = evidence_condition(checks, input);
                EvaluationStep::Continue(
                    self.next_node(node.id.as_str(), &condition)
                        .into_iter()
                        .collect(),
                )
            }
            PolicyGraphNodeKind::IfThenElse(condition) => {
                let branch = if_then_else_condition(*condition, input);
                EvaluationStep::Continue(
                    self.next_node(node.id.as_str(), &branch)
                        .into_iter()
                        .collect(),
                )
            }
            PolicyGraphNodeKind::Switch(switch) => EvaluationStep::Continue(
                self.next_node_for_port(node.id.as_str(), switch_port(switch, input))
                    .into_iter()
                    .collect(),
            ),
            PolicyGraphNodeKind::RiskClassifier {
                field, threshold, ..
            } => {
                let condition = risk_condition(*field, *threshold, input);
                EvaluationStep::Continue(
                    self.next_node(node.id.as_str(), &condition)
                        .into_iter()
                        .collect(),
                )
            }
            PolicyGraphNodeKind::Hub => EvaluationStep::Continue(self.next_nodes(node.id.as_str())),
            PolicyGraphNodeKind::HumanGate { reason_code } => {
                EvaluationStep::Terminal(require_human(*reason_code))
            }
            PolicyGraphNodeKind::ConsensusGate { reason_code } => {
                EvaluationStep::Terminal(require_consensus(*reason_code))
            }
            PolicyGraphNodeKind::ApprovalGate(gate) => {
                self.approval_gate_step(node, gate, input, effects)
            }
            PolicyGraphNodeKind::DryRunGate { reason_code } => {
                EvaluationStep::Terminal(dry_run_only(*reason_code))
            }
            PolicyGraphNodeKind::SupervisorRule {
                decision,
                reason_codes,
            } => EvaluationStep::Terminal(supervisor_decision(
                *decision,
                supervisor_reason_code(reason_codes),
            )),
            PolicyGraphNodeKind::Finish(finish) => {
                EvaluationStep::Terminal(supervisor_decision(finish.decision, finish.reason_code))
            }
        }
    }

    /// Evaluate an approval gate against the caller-supplied grant state:
    /// approved traverses the `approved` output, denied is terminal `Deny`,
    /// pending is terminal `RequireHuman`, and no grant additionally emits a
    /// fire-and-forget pending-grant request.
    fn approval_gate_step(
        &self,
        node: &PolicyGraphNode,
        gate: &super::PolicyApprovalGate,
        input: &PolicyInput,
        effects: &mut EvaluationEffects,
    ) -> EvaluationStep {
        match input.approval_state(node.id.as_str()) {
            Some(PolicyApprovalState::Approved) => EvaluationStep::Continue(
                self.next_node_for_port(node.id.as_str(), PORT_APPROVED)
                    .into_iter()
                    .collect(),
            ),
            Some(PolicyApprovalState::Denied) => EvaluationStep::Terminal(supervisor_decision(
                PolicyGraphDecision::Deny,
                gate.reason_code,
            )),
            Some(PolicyApprovalState::Pending) => {
                EvaluationStep::Terminal(require_human(gate.reason_code))
            }
            None => {
                effects.approval_requests.push(PolicyApprovalRequest {
                    node_id: node.id.as_str().to_owned(),
                    reason_code: gate.reason_code,
                    expiry_seconds: gate.expiry_seconds,
                });
                EvaluationStep::Terminal(require_human(gate.reason_code))
            }
        }
    }

    fn entry_node(&self, input: &PolicyInput) -> Option<&PolicyGraphNode> {
        if input.workflow.is_some() {
            return Self::matching_entry_node(&self.nodes, input);
        }
        self.fallback_entry_node()
    }

    fn next_node_for_action(&self, node_id: &str, action: PolicyAction) -> Option<String> {
        self.edges
            .iter()
            .find(|edge| {
                edge.from_node == node_id
                    && matches!(
                        &edge.condition,
                        PolicyGraphEdgeCondition::ActionIn { actions } if actions.contains(&action)
                    )
            })
            .or_else(|| {
                self.edges.iter().find(|edge| {
                    edge.from_node == node_id
                        && matches!(edge.condition, PolicyGraphEdgeCondition::Always)
                })
            })
            .map(|edge| edge.to_node.as_str().to_owned())
    }

    fn next_node_for_port(&self, node_id: &str, port: &str) -> Option<String> {
        self.edges
            .iter()
            .find(|edge| edge.from_node == node_id && edge.from_port == port)
            .map(|edge| edge.to_node.as_str().to_owned())
    }

    fn next_nodes(&self, node_id: &str) -> Vec<String> {
        let mut edges: Vec<_> = self
            .edges
            .iter()
            .filter(|edge| edge.from_node == node_id)
            .collect();
        edges.sort_by(|left, right| {
            left.from_port
                .cmp(&right.from_port)
                .then_with(|| left.id.cmp(&right.id))
        });
        edges
            .into_iter()
            .map(|edge| edge.to_node.as_str().to_owned())
            .collect()
    }

    fn matching_entry_node<'a>(
        nodes: &'a [PolicyGraphNode],
        input: &PolicyInput,
    ) -> Option<&'a PolicyGraphNode> {
        let workflow = input.workflow.as_deref()?;
        nodes.iter().find(|node| match &node.kind {
            PolicyGraphNodeKind::WorkflowEntry(entry) => {
                entry.workflow_id.eq_ignore_ascii_case(workflow)
            }
            PolicyGraphNodeKind::Trigger {
                workflow: node_workflow,
            } => node_workflow.eq_ignore_ascii_case(workflow),
            _ => false,
        })
    }

    fn fallback_entry_node(&self) -> Option<&PolicyGraphNode> {
        let workflow_node_ids = self.workflow_node_ids();
        self.nodes
            .iter()
            .find(|node| {
                node.input_ports.is_empty() && !workflow_node_ids.contains(node.id.as_str())
            })
            .or_else(|| {
                self.nodes.iter().find(|node| {
                    matches!(node.kind, PolicyGraphNodeKind::ActionGate { .. })
                        && !workflow_node_ids.contains(node.id.as_str())
                })
            })
    }

    fn workflow_node_ids(&self) -> HashSet<String> {
        let mut workflow_node_ids = HashSet::new();
        let mut pending: VecDeque<&str> = self
            .nodes
            .iter()
            .filter(|node| is_workflow_entry_node(node))
            .map(|node| node.id.as_str())
            .collect();
        while let Some(node_id) = pending.pop_front() {
            if !workflow_node_ids.insert(node_id.to_owned()) {
                continue;
            }
            pending.extend(
                self.edges
                    .iter()
                    .filter(|edge| edge.from_node == node_id)
                    .map(|edge| edge.to_node.as_str()),
            );
        }
        workflow_node_ids
    }

    fn next_node(&self, node_id: &str, condition: &PolicyGraphEdgeCondition) -> Option<String> {
        self.edges
            .iter()
            .find(|edge| {
                edge.from_node == node_id && edge_condition_matches(&edge.condition, condition)
            })
            .or_else(|| {
                self.edges.iter().find(|edge| {
                    edge.from_node == node_id
                        && matches!(edge.condition, PolicyGraphEdgeCondition::Always)
                })
            })
            .map(|edge| edge.to_node.as_str().to_owned())
    }
}

#[path = "evaluation_conditions.rs"]
mod conditions;
#[cfg(test)]
pub(super) use conditions::predicate_passes;
use conditions::{
    edge_condition_matches, evidence_condition, if_then_else_condition, is_workflow_entry_node,
    risk_condition, switch_port,
};

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing::warn! macro expands into a chain clippy reads as branchy"
)]
fn warn_cycle(visited: &[String], node_id: &str) {
    warn!(
        target: "harness::policy_graph",
        visit_path = ?visited,
        repeated_node = %node_id,
        "policy graph evaluation hit a cycle; bailing to human review",
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing::warn! macro expands into a chain clippy reads as branchy"
)]
fn warn_safety_cap(visited: &[String], safety_cap: usize) {
    warn!(
        target: "harness::policy_graph",
        visit_path = ?visited,
        safety_cap,
        "policy graph evaluation exceeded safety cap; bailing to human review",
    );
}
