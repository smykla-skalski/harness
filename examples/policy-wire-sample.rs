//! Round-trip oracle for the generated policy-graph Swift types.
//!
//! `emit` (default) prints real serde wire JSON for the seeded graph plus every
//! node-kind, decision, and predicate variant. `verify` reads JSON from stdin,
//! decodes it back into the Rust types, and asserts it equals the canonical
//! values. Feeding the Swift round-trip output to `verify` proves the generated
//! Codable preserves the serde wire format in both directions. Dev-only.

use std::io::Read as _;

use serde::{Deserialize, Serialize};

use harness::task_board::policy::{PolicyAction, PolicyDecision, PolicyReasonCode};
use harness::task_board::policy_graph::{
    PolicyActionStep, PolicyEventWait, PolicyEvidenceCheck, PolicyEvidenceField,
    PolicyEvidencePredicate, PolicyFinishNode, PolicyGraph, PolicyGraphDecision,
    PolicyGraphNodeKind, PolicyHandoffStep, PolicyIfThenElseCondition, PolicySwitchArm,
    PolicySwitchNode, PolicyWaitCondition, PolicyWaitStep, PolicyWorkflowEntry,
};

/// The full set of values exercised by the Swift round-trip.
#[derive(Debug, PartialEq, Serialize, Deserialize)]
struct Samples {
    graph: PolicyGraph,
    kinds: Vec<PolicyGraphNodeKind>,
    decisions: Vec<PolicyDecision>,
    predicates: Vec<PolicyEvidencePredicate>,
}

fn canonical() -> Samples {
    Samples {
        graph: PolicyGraph::seeded_v2(),
        kinds: all_node_kinds(),
        decisions: vec![
            PolicyDecision::Allow {
                reason_code: PolicyReasonCode::AutoMergeAllowed,
                policy_version: "task-board-policy-v1".to_string(),
            },
            PolicyDecision::RequireHuman {
                reason_code: PolicyReasonCode::HumanRequired,
                policy_version: "task-board-policy-v1".to_string(),
            },
            PolicyDecision::DryRunOnly {
                reason_code: PolicyReasonCode::DryRunRequired,
                policy_version: "task-board-policy-v1".to_string(),
            },
        ],
        predicates: vec![
            PolicyEvidencePredicate::IsTrue,
            PolicyEvidencePredicate::IsFalse,
            PolicyEvidencePredicate::IsZero,
            PolicyEvidencePredicate::IsPositive,
            PolicyEvidencePredicate::IsPresent,
            PolicyEvidencePredicate::IsMissing,
        ],
    }
}

/// One value per `PolicyGraphNodeKind` variant, covering unit, struct, and
/// newtype payloads plus the nested `switch` keyword and tagged inner enums.
fn all_node_kinds() -> Vec<PolicyGraphNodeKind> {
    use PolicyGraphNodeKind as Kind;
    vec![
        Kind::Trigger {
            workflow: "review".to_string(),
        },
        Kind::WorkflowEntry(PolicyWorkflowEntry {
            workflow_id: "wf-1".to_string(),
        }),
        Kind::ActionGate {
            actions: vec![PolicyAction::MergePr, PolicyAction::OpenPr],
        },
        Kind::ActionStep(PolicyActionStep {
            action_id: "act-1".to_string(),
        }),
        Kind::EvidenceCheck {
            checks: vec![PolicyEvidenceCheck {
                field: PolicyEvidenceField::ChecksGreen,
                pass: PolicyEvidencePredicate::IsTrue,
                fail_reason_code: PolicyReasonCode::ChecksNotGreen,
                missing_reason_code: PolicyReasonCode::MissingMergeEvidence,
            }],
        },
        Kind::IfThenElse(PolicyIfThenElseCondition {
            field: PolicyEvidenceField::RiskScore,
            predicate: PolicyEvidencePredicate::IsPositive,
        }),
        Kind::Switch(PolicySwitchNode {
            arms: vec![PolicySwitchArm {
                port: "high".to_string(),
                field: PolicyEvidenceField::RiskScore,
                predicate: PolicyEvidencePredicate::IsPositive,
            }],
        }),
        Kind::RiskClassifier {
            field: PolicyEvidenceField::RiskScore,
            threshold: 40,
            high_risk_reason_code: PolicyReasonCode::RiskAboveThreshold,
            missing_reason_code: PolicyReasonCode::MissingMergeEvidence,
        },
        Kind::WaitStep(PolicyWaitStep {
            wait: PolicyWaitCondition::Timer {
                duration_seconds: 30,
            },
            resume_key: "resume-1".to_string(),
        }),
        Kind::EventWait(PolicyEventWait {
            event_key: "evt-1".to_string(),
        }),
        Kind::Handoff(PolicyHandoffStep {
            handoff_key: "handoff-1".to_string(),
        }),
        Kind::Hub,
        Kind::HumanGate {
            reason_code: PolicyReasonCode::HumanRequired,
        },
        Kind::ConsensusGate {
            reason_code: PolicyReasonCode::ProtectedPathTouched,
        },
        Kind::DryRunGate {
            reason_code: PolicyReasonCode::DryRunRequired,
        },
        Kind::SupervisorRule {
            decision: PolicyGraphDecision::Allow,
            reason_codes: vec![PolicyReasonCode::DefaultAllow],
        },
        Kind::Finish(PolicyFinishNode {
            decision: PolicyGraphDecision::Deny,
            reason_code: PolicyReasonCode::HumanRequired,
        }),
        Kind::ReviewScreenshotPaste,
        Kind::OcrImage,
        Kind::ResolveReviewPullRequests,
        Kind::CopyReviewPullRequestList,
    ]
}

fn main() {
    if std::env::args().nth(1).as_deref() == Some("verify") {
        let mut input = String::new();
        std::io::stdin()
            .read_to_string(&mut input)
            .expect("read stdin");
        let parsed: Samples = serde_json::from_str(&input).expect("decode round-tripped JSON");
        assert_eq!(
            parsed,
            canonical(),
            "Swift round-trip changed the wire value"
        );
        println!("round-trip OK: {} node kinds preserved", parsed.kinds.len());
    } else {
        let json = serde_json::to_string_pretty(&canonical()).expect("serialize samples");
        println!("{json}");
    }
}
