//! Single source of truth for the policy-graph node-kind catalog.
//!
//! Every node kind has exactly one [`PolicyNodeKindDescriptor`] here. The
//! runtime resolves a kind's stable id and category from this table instead of
//! re-deriving them per call site, and the canvas palette is drift-tested
//! against the same catalog, so a new node kind is added in one place rather
//! than hardcoded across the seed, the palette, and the inspector.

use serde::{Deserialize, Serialize};

use super::{PORT_ELSE, PORT_IMAGE, PORT_PULL_REQUESTS, PORT_TEXT, PORT_THEN, PolicyGraphNodeKind};

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
///
/// `input_ports`/`output_ports` are the canonical *template* ports for a freshly
/// dropped node of this kind, matching the canvas palette. A concrete seeded
/// graph may legitimately diverge for config-derived gate nodes (an action gate
/// or evidence check derives its output ports from its configured matches), so
/// the seed is the configured instance and this descriptor is the template.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PolicyNodeKindDescriptor {
    pub id: &'static str,
    pub display_name: &'static str,
    pub category: PolicyNodeCategory,
    pub input_ports: &'static [&'static str],
    pub output_ports: &'static [&'static str],
}

/// The canonical node-kind catalog. Keep in sync with the enum variants (the
/// exhaustive `kind_id` match enforces that a new variant gets an id) and the
/// canvas palette (a Swift drift test enforces that side).
pub const POLICY_NODE_KIND_DESCRIPTORS: &[PolicyNodeKindDescriptor] = &[
    descriptor(
        "trigger",
        "Trigger",
        PolicyNodeCategory::Source,
        &[],
        &["event"],
    ),
    descriptor(
        "workflow_entry",
        "Workflow entry",
        PolicyNodeCategory::Source,
        &[],
        &["out"],
    ),
    descriptor(
        "review_screenshot_paste",
        "Review Screenshot Paste",
        PolicyNodeCategory::Source,
        &[],
        &[PORT_IMAGE],
    ),
    descriptor(
        "action_gate",
        "Action gate",
        PolicyNodeCategory::Condition,
        &["in"],
        &["match", "default"],
    ),
    descriptor(
        "evidence_check",
        "Evidence check",
        PolicyNodeCategory::Condition,
        &["in"],
        &["pass", "fail", "missing"],
    ),
    descriptor(
        "if_then_else",
        "If / then / else",
        PolicyNodeCategory::Condition,
        &["in"],
        &[PORT_THEN, PORT_ELSE],
    ),
    descriptor(
        "switch",
        "Switch",
        PolicyNodeCategory::Condition,
        &["in"],
        &["case_1", "default"],
    ),
    descriptor(
        "risk_classifier",
        "Risk classifier",
        PolicyNodeCategory::Condition,
        &["in"],
        &["low_or_equal", "high", "missing"],
    ),
    descriptor(
        "human_gate",
        "Human gate",
        PolicyNodeCategory::Review,
        &["in"],
        &[],
    ),
    descriptor(
        "consensus_gate",
        "Consensus gate",
        PolicyNodeCategory::Review,
        &["in"],
        &[],
    ),
    descriptor(
        "action_step",
        "Action step",
        PolicyNodeCategory::Transform,
        &["in"],
        &["out"],
    ),
    descriptor(
        "ocr_image",
        "OCR image",
        PolicyNodeCategory::Transform,
        &["in"],
        &[PORT_TEXT],
    ),
    descriptor(
        "resolve_review_pull_requests",
        "Resolve Reviews PRs",
        PolicyNodeCategory::Transform,
        &["in"],
        &[PORT_PULL_REQUESTS],
    ),
    descriptor(
        "copy_review_pull_request_list",
        "Copy PR list",
        PolicyNodeCategory::Transform,
        &["in"],
        &[],
    ),
    descriptor(
        "wait_step",
        "Wait step",
        PolicyNodeCategory::Transform,
        &["in"],
        &["out"],
    ),
    descriptor(
        "event_wait",
        "Event wait",
        PolicyNodeCategory::Transform,
        &["in"],
        &["out"],
    ),
    descriptor(
        "handoff",
        "Handoff",
        PolicyNodeCategory::Transform,
        &["in"],
        &["out"],
    ),
    descriptor(
        "dry_run_gate",
        "Dry-run gate",
        PolicyNodeCategory::Decision,
        &["in"],
        &[],
    ),
    descriptor(
        "supervisor_rule",
        "Supervisor rule",
        PolicyNodeCategory::Decision,
        &["in"],
        &[],
    ),
    descriptor(
        "finish",
        "Finish",
        PolicyNodeCategory::Decision,
        &["in"],
        &[],
    ),
];

const fn descriptor(
    id: &'static str,
    display_name: &'static str,
    category: PolicyNodeCategory,
    input_ports: &'static [&'static str],
    output_ports: &'static [&'static str],
) -> PolicyNodeKindDescriptor {
    PolicyNodeKindDescriptor {
        id,
        display_name,
        category,
        input_ports,
        output_ports,
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
            Self::IfThenElse(_) => "if_then_else",
            Self::Switch(_) => "switch",
            Self::RiskClassifier { .. } => "risk_classifier",
            Self::WaitStep(_) => "wait_step",
            Self::EventWait(_) => "event_wait",
            Self::Handoff(_) => "handoff",
            Self::HumanGate { .. } => "human_gate",
            Self::ConsensusGate { .. } => "consensus_gate",
            Self::DryRunGate { .. } => "dry_run_gate",
            Self::SupervisorRule { .. } => "supervisor_rule",
            Self::Finish(_) => "finish",
            Self::ReviewScreenshotPaste => "review_screenshot_paste",
            Self::OcrImage => "ocr_image",
            Self::ResolveReviewPullRequests => "resolve_review_pull_requests",
            Self::CopyReviewPullRequestList => "copy_review_pull_request_list",
        }
    }

    /// Catalog descriptor for this kind.
    ///
    /// # Panics
    /// Panics if the kind's id has no entry in [`POLICY_NODE_KIND_DESCRIPTORS`].
    /// This cannot happen for a well-formed catalog: the exhaustive `kind_id`
    /// match and the catalog are kept in sync, and `catalog_has_unique_ids`
    /// asserts every kind is covered.
    #[must_use]
    pub fn descriptor(&self) -> &'static PolicyNodeKindDescriptor {
        descriptor_for(self.kind_id()).expect("every node kind has a catalog descriptor")
    }

    /// Catalog category for this kind, resolved from the descriptor table.
    #[must_use]
    pub fn category(&self) -> PolicyNodeCategory {
        self.descriptor().category
    }

    /// Canonical template input ports for a freshly dropped node of this kind.
    /// A configured instance in a seeded graph may diverge for gate nodes whose
    /// ports are derived from config.
    #[must_use]
    pub fn template_input_ports(&self) -> &'static [&'static str] {
        self.descriptor().input_ports
    }

    /// Canonical template output ports for a freshly dropped node of this kind.
    /// A configured instance in a seeded graph may diverge for gate nodes whose
    /// ports are derived from config.
    #[must_use]
    pub fn template_output_ports(&self) -> &'static [&'static str] {
        self.descriptor().output_ports
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::policy::PolicyReasonCode;
    use crate::task_board::policy_graph::{
        PolicyFinishNode, PolicyGraphDecision, PolicyHandoffStep,
    };

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
        assert_eq!(total, 20, "catalog covers every node kind");
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
                PolicyGraphNodeKind::ReviewScreenshotPaste,
                "review_screenshot_paste",
                PolicyNodeCategory::Source,
            ),
            (
                PolicyGraphNodeKind::ResolveReviewPullRequests,
                "resolve_review_pull_requests",
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
    fn descriptor_template_ports_match_the_canvas_palette() {
        let expected: [(&str, &[&str], &[&str]); 20] = [
            ("trigger", &[], &["event"]),
            ("workflow_entry", &[], &["out"]),
            ("review_screenshot_paste", &[], &["image"]),
            ("action_gate", &["in"], &["match", "default"]),
            ("evidence_check", &["in"], &["pass", "fail", "missing"]),
            ("if_then_else", &["in"], &["then", "else"]),
            ("switch", &["in"], &["case_1", "default"]),
            (
                "risk_classifier",
                &["in"],
                &["low_or_equal", "high", "missing"],
            ),
            ("human_gate", &["in"], &[]),
            ("consensus_gate", &["in"], &[]),
            ("action_step", &["in"], &["out"]),
            ("ocr_image", &["in"], &["text"]),
            ("resolve_review_pull_requests", &["in"], &["pull_requests"]),
            ("copy_review_pull_request_list", &["in"], &[]),
            ("wait_step", &["in"], &["out"]),
            ("event_wait", &["in"], &["out"]),
            ("handoff", &["in"], &["out"]),
            ("dry_run_gate", &["in"], &[]),
            ("supervisor_rule", &["in"], &[]),
            ("finish", &["in"], &[]),
        ];
        assert_eq!(
            expected.len(),
            POLICY_NODE_KIND_DESCRIPTORS.len(),
            "template-port expectations cover every descriptor"
        );
        for (id, input_ports, output_ports) in expected {
            let descriptor = descriptor_for(id).expect("descriptor exists for canonical id");
            assert_eq!(
                descriptor.input_ports, input_ports,
                "{id} input ports match the canvas palette template"
            );
            assert_eq!(
                descriptor.output_ports, output_ports,
                "{id} output ports match the canvas palette template"
            );
        }
    }

    #[test]
    fn every_descriptor_has_at_least_one_template_port() {
        for descriptor in POLICY_NODE_KIND_DESCRIPTORS {
            let port_count = descriptor.input_ports.len() + descriptor.output_ports.len();
            assert!(port_count > 0, "{} has no template ports", descriptor.id);
        }
    }

    #[test]
    fn condition_kinds_expose_non_empty_template_output_ports() {
        for id in [
            "action_gate",
            "evidence_check",
            "if_then_else",
            "switch",
            "risk_classifier",
        ] {
            let descriptor = descriptor_for(id).expect("descriptor exists for condition id");
            assert_eq!(descriptor.input_ports, &["in"], "{id} takes a single input");
            assert!(
                !descriptor.output_ports.is_empty(),
                "{id} fans out to at least one output port"
            );
        }
    }

    #[test]
    fn if_then_else_descriptor_uses_binary_branch_ports() {
        let descriptor = descriptor_for("if_then_else").expect("if_then_else descriptor");
        assert_eq!(descriptor.category, PolicyNodeCategory::Condition);
        assert_eq!(descriptor.input_ports, &["in"]);
        assert_eq!(descriptor.output_ports, &["then", "else"]);
    }

    #[test]
    fn switch_descriptor_uses_case_and_default_ports() {
        let descriptor = descriptor_for("switch").expect("switch descriptor");
        assert_eq!(descriptor.category, PolicyNodeCategory::Condition);
        assert_eq!(descriptor.input_ports, &["in"]);
        assert_eq!(descriptor.output_ports, &["case_1", "default"]);
    }

    #[test]
    fn kind_template_port_accessors_resolve_from_the_descriptor() {
        let kind = PolicyGraphNodeKind::EvidenceCheck { checks: Vec::new() };
        assert_eq!(kind.template_input_ports(), &["in"]);
        assert_eq!(kind.template_output_ports(), &["pass", "fail", "missing"]);

        let descriptor = descriptor_for("evidence_check").expect("evidence_check descriptor");
        assert_eq!(kind.template_input_ports(), descriptor.input_ports);
        assert_eq!(kind.template_output_ports(), descriptor.output_ports);

        let trigger = PolicyGraphNodeKind::Trigger {
            workflow: "reviews_auto".to_owned(),
        };
        assert!(trigger.template_input_ports().is_empty());
        assert_eq!(trigger.template_output_ports(), &["event"]);
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
