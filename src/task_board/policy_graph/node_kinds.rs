//! Single source of truth for the policy-graph node-kind catalog.
//!
//! Every node kind has exactly one [`PolicyNodeKindDescriptor`] here. The
//! runtime resolves a kind's stable id and category from this table instead of
//! re-deriving them per call site, and the canvas palette is drift-tested
//! against the same catalog, so a new node kind is added in one place rather
//! than hardcoded across the seed, the palette, and the inspector.

use serde::{Deserialize, Serialize};

use super::PolicyGraphNodeKind;

/// Visual/semantic grouping for a node kind, mirrored by the canvas palette.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PolicyNodeCategory {
    Source,
    Condition,
    Review,
    Transform,
    Decision,
}

/// Catalog metadata for one node kind. `id` matches the kind's serde tag so the
/// descriptor and the serialized graph cannot drift.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PolicyNodeKindDescriptor {
    pub id: &'static str,
    pub display_name: &'static str,
    pub category: PolicyNodeCategory,
}

/// The canonical node-kind catalog. Keep in sync with the enum variants (the
/// exhaustive `kind_id` match enforces that a new variant gets an id) and the
/// canvas palette (a Swift drift test enforces that side).
pub const POLICY_NODE_KIND_DESCRIPTORS: &[PolicyNodeKindDescriptor] = &[
    descriptor("trigger", "Trigger", PolicyNodeCategory::Source),
    descriptor("workflow_entry", "Workflow entry", PolicyNodeCategory::Source),
    descriptor("action_gate", "Action gate", PolicyNodeCategory::Condition),
    descriptor("evidence_check", "Evidence check", PolicyNodeCategory::Condition),
    descriptor("risk_classifier", "Risk classifier", PolicyNodeCategory::Condition),
    descriptor("human_gate", "Human gate", PolicyNodeCategory::Review),
    descriptor("consensus_gate", "Consensus gate", PolicyNodeCategory::Review),
    descriptor("action_step", "Action step", PolicyNodeCategory::Transform),
    descriptor("wait_step", "Wait step", PolicyNodeCategory::Transform),
    descriptor("event_wait", "Event wait", PolicyNodeCategory::Transform),
    descriptor("handoff", "Handoff", PolicyNodeCategory::Transform),
    descriptor("dry_run_gate", "Dry-run gate", PolicyNodeCategory::Decision),
    descriptor("supervisor_rule", "Supervisor rule", PolicyNodeCategory::Decision),
    descriptor("finish", "Finish", PolicyNodeCategory::Decision),
];

const fn descriptor(
    id: &'static str,
    display_name: &'static str,
    category: PolicyNodeCategory,
) -> PolicyNodeKindDescriptor {
    PolicyNodeKindDescriptor {
        id,
        display_name,
        category,
    }
}

/// Look up a descriptor by its stable id.
#[must_use]
pub fn descriptor_for(id: &str) -> Option<&'static PolicyNodeKindDescriptor> {
    POLICY_NODE_KIND_DESCRIPTORS
        .iter()
        .find(|descriptor| descriptor.id == id)
}

impl PolicyGraphNodeKind {
    /// Stable id for this kind, identical to its serde `kind` tag.
    #[must_use]
    pub fn kind_id(&self) -> &'static str {
        match self {
            Self::Trigger { .. } => "trigger",
            Self::WorkflowEntry(_) => "workflow_entry",
            Self::ActionGate { .. } => "action_gate",
            Self::ActionStep(_) => "action_step",
            Self::EvidenceCheck { .. } => "evidence_check",
            Self::RiskClassifier { .. } => "risk_classifier",
            Self::WaitStep(_) => "wait_step",
            Self::EventWait(_) => "event_wait",
            Self::Handoff(_) => "handoff",
            Self::HumanGate { .. } => "human_gate",
            Self::ConsensusGate { .. } => "consensus_gate",
            Self::DryRunGate { .. } => "dry_run_gate",
            Self::SupervisorRule { .. } => "supervisor_rule",
            Self::Finish(_) => "finish",
        }
    }

    /// Catalog descriptor for this kind.
    #[must_use]
    pub fn descriptor(&self) -> &'static PolicyNodeKindDescriptor {
        descriptor_for(self.kind_id()).expect("every node kind has a catalog descriptor")
    }

    /// Catalog category for this kind, resolved from the descriptor table.
    #[must_use]
    pub fn category(&self) -> PolicyNodeCategory {
        self.descriptor().category
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::policy::PolicyReasonCode;
    use crate::task_board::policy_graph::{PolicyFinishNode, PolicyGraphDecision, PolicyHandoffStep};

    #[test]
    fn catalog_has_unique_ids() {
        let mut ids: Vec<&str> = POLICY_NODE_KIND_DESCRIPTORS
            .iter()
            .map(|descriptor| descriptor.id)
            .collect();
        let total = ids.len();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), total, "node-kind descriptor ids must be unique");
        assert_eq!(total, 14, "catalog covers every node kind");
    }

    #[test]
    fn every_descriptor_resolves_by_id() {
        for descriptor in POLICY_NODE_KIND_DESCRIPTORS {
            assert_eq!(descriptor_for(descriptor.id), Some(descriptor));
        }
        assert_eq!(descriptor_for("not_a_kind"), None);
    }

    #[test]
    fn kind_id_resolves_to_a_descriptor_with_the_expected_category() {
        let cases = [
            (
                PolicyGraphNodeKind::Trigger {
                    workflow: "reviews_auto".to_owned(),
                },
                "trigger",
                PolicyNodeCategory::Source,
            ),
            (
                PolicyGraphNodeKind::EvidenceCheck { checks: Vec::new() },
                "evidence_check",
                PolicyNodeCategory::Condition,
            ),
            (
                PolicyGraphNodeKind::HumanGate {
                    reason_code: PolicyReasonCode::HumanRequired,
                },
                "human_gate",
                PolicyNodeCategory::Review,
            ),
            (
                PolicyGraphNodeKind::Handoff(PolicyHandoffStep {
                    handoff_key: "next".to_owned(),
                }),
                "handoff",
                PolicyNodeCategory::Transform,
            ),
            (
                PolicyGraphNodeKind::Finish(PolicyFinishNode {
                    decision: PolicyGraphDecision::Allow,
                    reason_code: PolicyReasonCode::DefaultAllow,
                }),
                "finish",
                PolicyNodeCategory::Decision,
            ),
        ];
        for (kind, expected_id, expected_category) in cases {
            assert_eq!(kind.kind_id(), expected_id);
            assert_eq!(kind.category(), expected_category);
            assert_eq!(kind.descriptor().id, expected_id);
        }
    }

    #[test]
    fn kind_id_matches_the_serde_tag() {
        let kind = PolicyGraphNodeKind::Handoff(PolicyHandoffStep {
            handoff_key: "next".to_owned(),
        });
        let value = serde_json::to_value(&kind).expect("serialize kind");
        assert_eq!(value["kind"].as_str(), Some(kind.kind_id()));
    }
}
