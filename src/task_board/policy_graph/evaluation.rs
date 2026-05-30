use std::collections::HashSet;

use tracing::warn;

use super::{
    PolicyDecision, PolicyEvidenceCheck, PolicyEvidenceField, PolicyEvidencePredicate, PolicyGraph,
    PolicyGraphDecision, PolicyGraphEdgeCondition, PolicyGraphNode, PolicyGraphNodeKind,
    PolicyIfThenElseCondition, PolicyReasonCode, PolicyRuntimeBoundary,
};
use crate::task_board::policy::{PolicyAction, PolicyInput, TASK_BOARD_POLICY_VERSION};

enum EvaluationStep {
    Continue(String),
    Terminal(PolicyDecision),
}

impl PolicyGraph {
    pub(super) fn evaluate_graph(
        &self,
        input: &PolicyInput,
    ) -> Option<(PolicyDecision, Vec<String>, Vec<PolicyRuntimeBoundary>)> {
        if !self.validate().is_valid() {
            return Some((
                require_human(PolicyReasonCode::HumanRequired),
                Vec::new(),
                Vec::new(),
            ));
        }
        let mut node_id = self.entry_node(input)?.id.clone();
        let mut visited = Vec::new();
        let mut visited_ids: HashSet<String> = HashSet::new();
        let mut boundaries = Vec::new();
        let safety_cap = self.nodes.len().saturating_mul(4).max(4);
        loop {
            if let Some(bailout) =
                Self::traversal_bailout(node_id.as_str(), &visited, &mut visited_ids, safety_cap)
            {
                return Some((bailout.0, bailout.1, boundaries));
            }
            let node = self
                .nodes
                .iter()
                .find(|candidate| candidate.id == node_id)?;
            visited.push(node.id.clone());
            match self.evaluation_step(node, input, &mut boundaries)? {
                EvaluationStep::Continue(next_node_id) => node_id = next_node_id,
                EvaluationStep::Terminal(decision) => return Some((decision, visited, boundaries)),
            }
        }
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
        boundaries: &mut Vec<PolicyRuntimeBoundary>,
    ) -> Option<EvaluationStep> {
        match &node.kind {
            PolicyGraphNodeKind::Trigger { .. }
            | PolicyGraphNodeKind::WorkflowEntry(_)
            | PolicyGraphNodeKind::ActionStep(_)
            | PolicyGraphNodeKind::EventWait(_)
            | PolicyGraphNodeKind::Handoff(_) => Some(EvaluationStep::Continue(
                self.next_node(&node.id, &PolicyGraphEdgeCondition::Always)?,
            )),
            PolicyGraphNodeKind::WaitStep(step) => {
                boundaries.push(PolicyRuntimeBoundary {
                    node_id: node.id.clone(),
                    resume_key: step.resume_key.clone(),
                    wait: step.wait.clone(),
                });
                Some(EvaluationStep::Continue(
                    self.next_node(&node.id, &PolicyGraphEdgeCondition::Always)?,
                ))
            }
            PolicyGraphNodeKind::ActionGate { .. } => Some(EvaluationStep::Continue(
                self.next_node_for_action(&node.id, input.action)?,
            )),
            PolicyGraphNodeKind::EvidenceCheck { checks } => {
                let condition = evidence_condition(checks, input);
                Some(EvaluationStep::Continue(
                    self.next_node(&node.id, &condition)?,
                ))
            }
            PolicyGraphNodeKind::IfThenElse(condition) => {
                let branch = if_then_else_condition(*condition, input);
                Some(EvaluationStep::Continue(
                    self.next_node(&node.id, &branch)?,
                ))
            }
            PolicyGraphNodeKind::RiskClassifier {
                field, threshold, ..
            } => {
                let condition = risk_condition(*field, *threshold, input);
                Some(EvaluationStep::Continue(
                    self.next_node(&node.id, &condition)?,
                ))
            }
            PolicyGraphNodeKind::HumanGate { reason_code } => {
                Some(EvaluationStep::Terminal(require_human(*reason_code)))
            }
            PolicyGraphNodeKind::ConsensusGate { reason_code } => {
                Some(EvaluationStep::Terminal(require_consensus(*reason_code)))
            }
            PolicyGraphNodeKind::DryRunGate { reason_code } => {
                Some(EvaluationStep::Terminal(dry_run_only(*reason_code)))
            }
            PolicyGraphNodeKind::SupervisorRule {
                decision,
                reason_codes,
            } => Some(EvaluationStep::Terminal(supervisor_decision(
                *decision,
                supervisor_reason_code(reason_codes),
            ))),
            PolicyGraphNodeKind::Finish(finish) => Some(EvaluationStep::Terminal(
                supervisor_decision(finish.decision, finish.reason_code),
            )),
        }
    }

    fn entry_node(&self, input: &PolicyInput) -> Option<&PolicyGraphNode> {
        Self::matching_entry_node(&self.nodes, input)
            .or_else(|| Self::fallback_entry_node(&self.nodes))
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
            .map(|edge| edge.to_node.clone())
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

    fn fallback_entry_node(nodes: &[PolicyGraphNode]) -> Option<&PolicyGraphNode> {
        nodes
            .iter()
            .find(|node| {
                matches!(
                    node.kind,
                    PolicyGraphNodeKind::Trigger { .. } | PolicyGraphNodeKind::WorkflowEntry(_)
                )
            })
            .or_else(|| {
                nodes
                    .iter()
                    .find(|node| matches!(node.kind, PolicyGraphNodeKind::ActionGate { .. }))
            })
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
            .map(|edge| edge.to_node.clone())
    }
}

fn evidence_condition(
    checks: &[PolicyEvidenceCheck],
    input: &PolicyInput,
) -> PolicyGraphEdgeCondition {
    for check in checks {
        let Some(value) = evidence_value(check.field, input) else {
            return PolicyGraphEdgeCondition::EvidenceMissing;
        };
        if !predicate_passes(check.pass, value) {
            if check.fail_reason_code == PolicyReasonCode::ProtectedPathTouched {
                return PolicyGraphEdgeCondition::EvidenceConsensus {
                    reason_code: check.fail_reason_code,
                };
            }
            return PolicyGraphEdgeCondition::EvidenceFailure {
                reason_code: check.fail_reason_code,
            };
        }
    }
    PolicyGraphEdgeCondition::EvidencePass
}

fn if_then_else_condition(
    condition: PolicyIfThenElseCondition,
    input: &PolicyInput,
) -> PolicyGraphEdgeCondition {
    let Some(value) = evidence_value(condition.field, input) else {
        return PolicyGraphEdgeCondition::ConditionFalse;
    };
    if predicate_passes(condition.predicate, value) {
        PolicyGraphEdgeCondition::ConditionTrue
    } else {
        PolicyGraphEdgeCondition::ConditionFalse
    }
}

fn risk_condition(
    field: PolicyEvidenceField,
    threshold: u8,
    input: &PolicyInput,
) -> PolicyGraphEdgeCondition {
    let Some(risk_score) = risk_value(field, input) else {
        return PolicyGraphEdgeCondition::RiskMissing;
    };
    if risk_score > threshold {
        PolicyGraphEdgeCondition::RiskHigh
    } else {
        PolicyGraphEdgeCondition::RiskLowOrEqual
    }
}

fn evidence_value(field: PolicyEvidenceField, input: &PolicyInput) -> Option<u32> {
    match field {
        PolicyEvidenceField::ChecksGreen => input.evidence.checks_green.map(u32::from),
        PolicyEvidenceField::BranchProtectionAllowsMerge => {
            input.evidence.branch_protection_allows_merge.map(u32::from)
        }
        PolicyEvidenceField::ReviewerVerdictApproved => {
            input.evidence.reviewer_verdict_approved.map(u32::from)
        }
        PolicyEvidenceField::UnresolvedRequestedChanges => {
            input.evidence.unresolved_requested_changes
        }
        PolicyEvidenceField::ProtectedPathTouched => {
            input.evidence.protected_path_touched.map(u32::from)
        }
        PolicyEvidenceField::RiskScore => input.evidence.risk_score.map(u32::from),
        PolicyEvidenceField::ReviewIsOpen => input.evidence.review_is_open.map(u32::from),
        PolicyEvidenceField::ReviewIsDraft => input.evidence.review_is_draft.map(u32::from),
        PolicyEvidenceField::ReviewReviewRequired => {
            input.evidence.review_review_required.map(u32::from)
        }
        PolicyEvidenceField::ReviewHasNoDecision => {
            input.evidence.review_has_no_decision.map(u32::from)
        }
        PolicyEvidenceField::ReviewHasMergeConflicts => {
            input.evidence.review_has_merge_conflicts.map(u32::from)
        }
        PolicyEvidenceField::ReviewPolicyBlocked => {
            input.evidence.review_policy_blocked.map(u32::from)
        }
        PolicyEvidenceField::ReviewViewerCanUpdate => {
            input.evidence.review_viewer_can_update.map(u32::from)
        }
    }
}

fn risk_value(field: PolicyEvidenceField, input: &PolicyInput) -> Option<u8> {
    match field {
        PolicyEvidenceField::RiskScore => input.evidence.risk_score,
        _ => evidence_value(field, input).and_then(|value| u8::try_from(value).ok()),
    }
}

pub(super) const fn predicate_passes(predicate: PolicyEvidencePredicate, value: u32) -> bool {
    match predicate {
        PolicyEvidencePredicate::IsTrue => value == 1,
        PolicyEvidencePredicate::IsFalse | PolicyEvidencePredicate::IsZero => value == 0,
        PolicyEvidencePredicate::IsPositive => value > 0,
    }
}

fn edge_condition_matches(
    candidate: &PolicyGraphEdgeCondition,
    target: &PolicyGraphEdgeCondition,
) -> bool {
    match (candidate, target) {
        (PolicyGraphEdgeCondition::Always, PolicyGraphEdgeCondition::Always)
        | (PolicyGraphEdgeCondition::ConditionTrue, PolicyGraphEdgeCondition::ConditionTrue)
        | (PolicyGraphEdgeCondition::ConditionFalse, PolicyGraphEdgeCondition::ConditionFalse)
        | (PolicyGraphEdgeCondition::EvidencePass, PolicyGraphEdgeCondition::EvidencePass)
        | (PolicyGraphEdgeCondition::EvidenceMissing, PolicyGraphEdgeCondition::EvidenceMissing)
        | (PolicyGraphEdgeCondition::RiskHigh, PolicyGraphEdgeCondition::RiskHigh)
        | (PolicyGraphEdgeCondition::RiskLowOrEqual, PolicyGraphEdgeCondition::RiskLowOrEqual)
        | (PolicyGraphEdgeCondition::RiskMissing, PolicyGraphEdgeCondition::RiskMissing) => true,
        (
            PolicyGraphEdgeCondition::EvidenceFailure {
                reason_code: candidate,
            },
            PolicyGraphEdgeCondition::EvidenceFailure {
                reason_code: target,
            },
        )
        | (
            PolicyGraphEdgeCondition::EvidenceConsensus {
                reason_code: candidate,
            },
            PolicyGraphEdgeCondition::EvidenceConsensus {
                reason_code: target,
            },
        ) => candidate == target,
        _ => false,
    }
}

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

fn supervisor_reason_code(reason_codes: &[PolicyReasonCode]) -> PolicyReasonCode {
    reason_codes
        .first()
        .copied()
        .unwrap_or(PolicyReasonCode::DefaultAllow)
}

fn supervisor_decision(
    decision: PolicyGraphDecision,
    reason_code: PolicyReasonCode,
) -> PolicyDecision {
    match decision {
        PolicyGraphDecision::Allow => allow(reason_code),
        PolicyGraphDecision::Deny => deny(reason_code),
    }
}

fn allow(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::Allow {
        reason_code,
        policy_version: TASK_BOARD_POLICY_VERSION.to_string(),
    }
}

fn deny(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::Deny {
        reason_code,
        policy_version: TASK_BOARD_POLICY_VERSION.to_string(),
    }
}

fn require_human(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::RequireHuman {
        reason_code,
        policy_version: TASK_BOARD_POLICY_VERSION.to_string(),
    }
}

fn require_consensus(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::RequireConsensus {
        reason_code,
        policy_version: TASK_BOARD_POLICY_VERSION.to_string(),
    }
}

fn dry_run_only(reason_code: PolicyReasonCode) -> PolicyDecision {
    PolicyDecision::DryRunOnly {
        reason_code,
        policy_version: TASK_BOARD_POLICY_VERSION.to_string(),
    }
}
