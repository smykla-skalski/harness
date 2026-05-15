use super::{
    PolicyDecision, PolicyEvidenceCheck, PolicyEvidenceField, PolicyEvidencePredicate, PolicyGraph,
    PolicyGraphDecision, PolicyGraphEdgeCondition, PolicyGraphNodeKind, PolicyReasonCode,
};
use crate::task_board::policy::{PolicyAction, PolicyInput, TASK_BOARD_POLICY_VERSION};

impl PolicyGraph {
    pub(super) fn evaluate_graph(
        &self,
        input: &PolicyInput,
    ) -> Option<(PolicyDecision, Vec<String>)> {
        if !self.validate().is_valid() {
            return Some((require_human(PolicyReasonCode::HumanRequired), Vec::new()));
        }
        let mut node_id = self.entry_node_id()?;
        let mut visited = Vec::new();
        for _ in 0..self.nodes.len().saturating_add(1) {
            let node = self
                .nodes
                .iter()
                .find(|candidate| candidate.id == node_id)?;
            visited.push(node.id.clone());
            match &node.kind {
                PolicyGraphNodeKind::Trigger { .. } => {
                    node_id = self.next_node(&node.id, &PolicyGraphEdgeCondition::Always)?;
                }
                PolicyGraphNodeKind::ActionGate { .. } => {
                    node_id = self.next_node_for_action(&node.id, input.action)?;
                }
                PolicyGraphNodeKind::EvidenceCheck { checks } => {
                    let condition = evidence_condition(checks, input);
                    node_id = self.next_node(&node.id, &condition)?;
                }
                PolicyGraphNodeKind::RiskClassifier {
                    field, threshold, ..
                } => {
                    let condition = risk_condition(*field, *threshold, input);
                    node_id = self.next_node(&node.id, &condition)?;
                }
                PolicyGraphNodeKind::HumanGate { reason_code } => {
                    return Some((require_human(*reason_code), visited));
                }
                PolicyGraphNodeKind::ConsensusGate { reason_code } => {
                    return Some((require_consensus(*reason_code), visited));
                }
                PolicyGraphNodeKind::DryRunGate { reason_code } => {
                    return Some((dry_run_only(*reason_code), visited));
                }
                PolicyGraphNodeKind::SupervisorRule {
                    decision,
                    reason_codes,
                } => {
                    let reason_code = reason_codes
                        .first()
                        .copied()
                        .unwrap_or(PolicyReasonCode::DefaultAllow);
                    return Some((supervisor_decision(*decision, reason_code), visited));
                }
            }
        }
        Some((require_human(PolicyReasonCode::HumanRequired), visited))
    }

    fn entry_node_id(&self) -> Option<String> {
        self.nodes
            .iter()
            .find(|node| matches!(node.kind, PolicyGraphNodeKind::Trigger { .. }))
            .or_else(|| {
                self.nodes
                    .iter()
                    .find(|node| matches!(node.kind, PolicyGraphNodeKind::ActionGate { .. }))
            })
            .map(|node| node.id.clone())
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
