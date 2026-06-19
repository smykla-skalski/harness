#![expect(
    clippy::module_name_repetitions,
    reason = "PolicyGraph* names mirror the protocol contract surfaced to clients"
)]

use serde::{Deserialize, Serialize};

use super::policy::{
    BuiltInPolicyGate, DEFAULT_AUTO_MERGE_RISK_THRESHOLD, PolicyAction, PolicyDecision, PolicyGate,
    PolicyInput, PolicyReasonCode, TASK_BOARD_POLICY_VERSION,
};

mod compiler;
mod decisions;
mod defaults;
mod evaluation;
mod gate_cache;
mod graph_impls;
mod ids;
mod models;
mod node_kinds;
mod seed;
mod store;
mod store_canvas;
mod validation;
mod workspace;

#[cfg(test)]
mod tests;

pub const POLICY_GRAPH_SCHEMA_VERSION: u16 = 2;
pub const POLICY_GRAPH_INITIAL_REVISION: u64 = 1;

pub use compiler::{CompiledWorkflowPlan, CompiledWorkflowStep};
pub(crate) use decisions::{RecordedPolicyDecision, install_decision_sink, record_policy_decision};
pub(crate) use gate_cache::{
    cached_gate_policy, install_gate_coldfill, resolve_gate_policy, store_gate_policy,
};
pub use ids::{PolicyGraphEdgeId, PolicyGraphGroupId, PolicyGraphNodeId, PolicyGraphPortId};
pub use models::{
    PolicyActionStep, PolicyEventWait, PolicyFinishNode, PolicyGraphAutomationBinding,
    PolicyGraphOCRConfiguration, PolicyGraphReviewPullRequestExtraction, PolicyHandoffStep,
    PolicyRuntimeBoundary, PolicyWaitCondition, PolicyWaitStep, PolicyWorkflowEntry,
};
pub use node_kinds::{
    POLICY_NODE_KIND_DESCRIPTORS, PolicyNodeCategory, PolicyNodeKindDescriptor, descriptor_for,
};
pub use store::{
    GraphPolicyGate, PolicyPipelineAuditSummary, PolicyPipelinePromoteRequest,
    PolicyPipelinePromoteResponse, PolicyPipelineSaveResponse, PolicyPipelineSimulatedDecision,
    PolicyPipelineSimulationResult, apply_promote, apply_save_canvas_draft, apply_save_draft,
    apply_simulate, audit_summary, read_active_document,
};
pub use store_canvas::{
    apply_create, apply_delete, apply_duplicate, apply_import, apply_rename, apply_set_active,
    apply_set_global_enforcement,
};
pub use workspace::{
    DEFAULT_POLICY_CANVAS_TITLE, MANUAL_OCR_PASTE_CANVAS_TITLE, PolicyCanvasRecord,
    PolicyCanvasWorkspace, REVIEW_SCREENSHOT_EXTRACTION_CANVAS_TITLE,
    REVIEW_TEXT_PASTE_DRY_RUN_CANVAS_TITLE,
};

pub(crate) const PORT_IN: &str = "in";
pub(crate) const PORT_DEFAULT: &str = "default";
pub(crate) const PORT_IMAGE: &str = "image";
pub(crate) const PORT_TEXT: &str = "text";
pub(crate) const PORT_PULL_REQUESTS: &str = "pull_requests";
pub(crate) const PORT_MUTATE: &str = "mutate";
pub(crate) const PORT_MERGE: &str = "merge";
pub(crate) const PORT_UNSAFE: &str = "unsafe";
pub(crate) const PORT_PASS: &str = "pass";
pub(crate) const PORT_FAIL: &str = "fail";
pub(crate) const PORT_CONSENSUS: &str = "consensus";
pub(crate) const PORT_MISSING: &str = "missing";
pub(crate) const PORT_THEN: &str = "then";
pub(crate) const PORT_ELSE: &str = "else";
pub(crate) const PORT_HIGH: &str = "high";
pub(crate) const PORT_LOW_OR_EQUAL: &str = "low_or_equal";

pub(crate) const UNSAFE_HIGH_RISK_ACTIONS: [PolicyAction; 3] = [
    PolicyAction::DeleteWorktree,
    PolicyAction::AccessSecret,
    PolicyAction::DestructiveFs,
];

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PolicyGraph {
    pub schema_version: u16,
    pub revision: u64,
    pub mode: PolicyGraphMode,
    pub nodes: Vec<PolicyGraphNode>,
    pub edges: Vec<PolicyGraphEdge>,
    pub groups: Vec<PolicyGraphGroup>,
    pub layout: PolicyGraphLayout,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub policy_trace_ids: Vec<String>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PolicyGraphMode {
    #[default]
    Draft,
    DryRun,
    Enforced,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyGraphNode {
    pub id: PolicyGraphNodeId,
    pub label: String,
    pub kind: PolicyGraphNodeKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub automation: Option<PolicyGraphAutomationBinding>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub input_ports: Vec<PolicyGraphPortId>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub output_ports: Vec<PolicyGraphPortId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group_id: Option<PolicyGraphGroupId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PolicyGraphNodeKind {
    Trigger {
        workflow: String,
    },
    WorkflowEntry(PolicyWorkflowEntry),
    ActionGate {
        actions: Vec<PolicyAction>,
    },
    ActionStep(PolicyActionStep),
    EvidenceCheck {
        checks: Vec<PolicyEvidenceCheck>,
    },
    IfThenElse(PolicyIfThenElseCondition),
    Switch(PolicySwitchNode),
    RiskClassifier {
        field: PolicyEvidenceField,
        threshold: u8,
        high_risk_reason_code: PolicyReasonCode,
        missing_reason_code: PolicyReasonCode,
    },
    WaitStep(PolicyWaitStep),
    EventWait(PolicyEventWait),
    Handoff(PolicyHandoffStep),
    Hub,
    HumanGate {
        reason_code: PolicyReasonCode,
    },
    ConsensusGate {
        reason_code: PolicyReasonCode,
    },
    DryRunGate {
        reason_code: PolicyReasonCode,
    },
    SupervisorRule {
        decision: PolicyGraphDecision,
        reason_codes: Vec<PolicyReasonCode>,
    },
    Finish(PolicyFinishNode),
    ReviewScreenshotPaste,
    OcrImage,
    ResolveReviewPullRequests,
    CopyReviewPullRequestList,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PolicyGraphDecision {
    Allow,
    Deny,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PolicyEvidenceField {
    ChecksGreen,
    BranchProtectionAllowsMerge,
    ReviewerVerdictApproved,
    UnresolvedRequestedChanges,
    ProtectedPathTouched,
    RiskScore,
    ReviewIsOpen,
    ReviewIsDraft,
    ReviewReviewRequired,
    ReviewHasNoDecision,
    ReviewHasMergeConflicts,
    ReviewPolicyBlocked,
    ReviewViewerCanUpdate,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "predicate", rename_all = "snake_case")]
pub enum PolicyEvidencePredicate {
    IsTrue,
    IsFalse,
    IsZero,
    IsPositive,
    IsPresent,
    IsMissing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyEvidenceCheck {
    pub field: PolicyEvidenceField,
    pub pass: PolicyEvidencePredicate,
    pub fail_reason_code: PolicyReasonCode,
    pub missing_reason_code: PolicyReasonCode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyIfThenElseCondition {
    pub field: PolicyEvidenceField,
    pub predicate: PolicyEvidencePredicate,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicySwitchNode {
    pub arms: Vec<PolicySwitchArm>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicySwitchArm {
    pub port: PolicyGraphPortId,
    pub field: PolicyEvidenceField,
    pub predicate: PolicyEvidencePredicate,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyGraphEdge {
    pub id: PolicyGraphEdgeId,
    pub from_node: PolicyGraphNodeId,
    pub from_port: PolicyGraphPortId,
    pub to_node: PolicyGraphNodeId,
    pub to_port: PolicyGraphPortId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default)]
    pub condition: PolicyGraphEdgeCondition,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "condition", rename_all = "snake_case")]
pub enum PolicyGraphEdgeCondition {
    #[default]
    Always,
    ActionIn {
        actions: Vec<PolicyAction>,
    },
    EvidencePass,
    EvidenceFailure {
        reason_code: PolicyReasonCode,
    },
    EvidenceConsensus {
        reason_code: PolicyReasonCode,
    },
    EvidenceMissing,
    ConditionTrue,
    ConditionFalse,
    RiskHigh,
    RiskLowOrEqual,
    RiskMissing,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyGraphGroup {
    pub id: PolicyGraphGroupId,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default)]
    pub frame: PolicyCanvasRect,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub node_ids: Vec<PolicyGraphNodeId>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PolicyGraphLayout {
    #[serde(
        default = "defaults::default_policy_graph_zoom",
        skip_serializing_if = "defaults::is_default_policy_graph_zoom"
    )]
    pub zoom: f64,
    #[serde(
        default,
        skip_serializing_if = "defaults::is_default_policy_canvas_point"
    )]
    pub offset: PolicyCanvasPoint,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub nodes: Vec<PolicyGraphNodeLayout>,
}

impl Default for PolicyGraphLayout {
    fn default() -> Self {
        Self {
            zoom: defaults::default_policy_graph_zoom(),
            offset: PolicyCanvasPoint::default(),
            nodes: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyGraphNodeLayout {
    pub node_id: PolicyGraphNodeId,
    pub x: i32,
    pub y: i32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<PolicyGraphNodeLayoutSource>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PolicyGraphNodeLayoutSource {
    Auto,
    Manual,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyGraphValidationReport {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub issues: Vec<PolicyGraphValidationIssue>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "issue", rename_all = "snake_case")]
pub enum PolicyGraphValidationIssue {
    UnsupportedSchemaVersion {
        expected: u16,
        actual: u16,
    },
    DuplicateId {
        id: String,
        location: String,
    },
    DanglingEdge {
        edge_id: String,
        node_id: String,
    },
    InvalidPort {
        edge_id: String,
        node_id: String,
        port: String,
        direction: PolicyGraphPortDirection,
    },
    Cycle {
        node_ids: Vec<String>,
    },
    UnsafeHighRiskAction {
        action: PolicyAction,
    },
    IncompatiblePayloadEdge {
        edge_id: String,
        provided: String,
        required: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PolicyGraphPortDirection {
    Input,
    Output,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyGraphSimulation {
    pub mode: PolicyGraphMode,
    pub decision: PolicyDecision,
    #[serde(default)]
    pub trace: PolicySimulationTrace,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub visited_node_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub policy_trace_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub boundaries: Vec<PolicyRuntimeBoundary>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicySimulationTrace {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entry_node_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub visited_node_ids: Vec<String>,
}

pub type PolicyPipelineDocument = PolicyGraph;
pub type PolicyPipelineMode = PolicyGraphMode;
pub type PolicyPipelineNode = PolicyGraphNode;
pub type PolicyPipelineNodeKind = PolicyGraphNodeKind;
pub type PolicyPipelineEdge = PolicyGraphEdge;
pub type PolicyPipelineGroup = PolicyGraphGroup;
pub type PolicyPipelineLayout = PolicyGraphLayout;
pub type PolicyPipelineValidation = PolicyGraphValidationReport;
pub type PolicyPipelineValidationIssue = PolicyGraphValidationIssue;
pub type PolicyPipelineValidationCode = PolicyGraphValidationIssue;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyPipelinePort {
    pub id: PolicyGraphPortId,
    pub label: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyCanvasPoint {
    pub x: i32,
    pub y: i32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyCanvasRect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl Default for PolicyGraph {
    fn default() -> Self {
        Self::seeded_v2()
    }
}

impl PolicyGraph {
    #[must_use]
    pub fn seeded_v2() -> Self {
        let nodes = seed::seeded_nodes();
        Self {
            schema_version: POLICY_GRAPH_SCHEMA_VERSION,
            revision: POLICY_GRAPH_INITIAL_REVISION,
            mode: PolicyGraphMode::Draft,
            edges: seed::seeded_edges(),
            groups: seed::seeded_groups(),
            layout: seed::layout_for(&nodes),
            nodes,
            policy_trace_ids: vec![
                TASK_BOARD_POLICY_VERSION.to_string(),
                "task-board-policy-graph-v2".to_string(),
            ],
        }
    }

    #[must_use]
    pub fn review_text_paste_dry_run_seeded_v2() -> Self {
        seed::review_text_paste_dry_run_document()
    }

    #[must_use]
    pub fn manual_ocr_paste_seeded_v2() -> Self {
        seed::manual_ocr_paste_document()
    }

    #[must_use]
    pub fn review_screenshot_extraction_seeded_v2() -> Self {
        seed::review_screenshot_extraction_document()
    }

    #[must_use]
    pub fn with_mode(mut self, mode: PolicyGraphMode) -> Self {
        self.mode = mode;
        self
    }

    #[must_use]
    pub fn validate(&self) -> PolicyGraphValidationReport {
        validation::validate(self)
    }

    #[must_use]
    pub fn simulate(&self, input: &PolicyInput) -> PolicyGraphSimulation {
        let (decision, visited_node_ids, boundaries) =
            self.evaluate_graph(input).unwrap_or_else(|| {
                let decision =
                    BuiltInPolicyGate::new(self.auto_merge_risk_threshold()).evaluate(input);
                let visited_node_ids = seed::trace_for(self, input, &decision);
                (decision, visited_node_ids, Vec::new())
            });
        PolicyGraphSimulation {
            mode: self.mode,
            trace: PolicySimulationTrace {
                entry_node_id: visited_node_ids.first().cloned(),
                visited_node_ids: visited_node_ids.clone(),
            },
            visited_node_ids,
            policy_trace_ids: self.policy_trace_ids.clone(),
            boundaries,
            decision,
        }
    }

    /// Validate and move this graph to a target mode and revision.
    ///
    /// # Errors
    /// Returns validation issues when the graph is not safe to promote.
    pub fn promoted(
        mut self,
        mode: PolicyGraphMode,
        revision: u64,
    ) -> Result<Self, PolicyGraphValidationReport> {
        let report = self.validate();
        if !report.is_valid() {
            return Err(report);
        }
        self.mode = mode;
        self.revision = revision;
        Ok(self)
    }
}
