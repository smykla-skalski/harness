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
mod evaluation;
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
pub use node_kinds::{
    POLICY_NODE_KIND_DESCRIPTORS, PolicyNodeCategory, PolicyNodeKindDescriptor, descriptor_for,
};
pub use store::{
    GraphPolicyGate, PolicyPipelineAuditSummary, PolicyPipelinePromoteRequest,
    PolicyPipelinePromoteResponse, PolicyPipelineSaveResponse, PolicyPipelineSimulatedDecision,
    PolicyPipelineSimulationResult, PolicyPipelineStore,
};
pub use workspace::{
    PRIMARY_POLICY_CANVAS_TITLE, PolicyCanvasRecord, PolicyCanvasWorkspace,
    PolicyCanvasWorkspaceStore,
};

pub(crate) const PORT_IN: &str = "in";
pub(crate) const PORT_DEFAULT: &str = "default";
pub(crate) const PORT_MUTATE: &str = "mutate";
pub(crate) const PORT_MERGE: &str = "merge";
pub(crate) const PORT_UNSAFE: &str = "unsafe";
pub(crate) const PORT_PASS: &str = "pass";
pub(crate) const PORT_FAIL: &str = "fail";
pub(crate) const PORT_CONSENSUS: &str = "consensus";
pub(crate) const PORT_MISSING: &str = "missing";
pub(crate) const PORT_HIGH: &str = "high";
pub(crate) const PORT_LOW_OR_EQUAL: &str = "low_or_equal";

pub(crate) const UNSAFE_HIGH_RISK_ACTIONS: [PolicyAction; 3] = [
    PolicyAction::DeleteWorktree,
    PolicyAction::AccessSecret,
    PolicyAction::DestructiveFs,
];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
    pub id: String,
    pub label: String,
    pub kind: PolicyGraphNodeKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub automation: Option<PolicyGraphAutomationBinding>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub input_ports: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub output_ports: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyGraphAutomationBinding {
    #[serde(default = "default_automation_enabled")]
    pub is_enabled: bool,
    pub event_source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<i32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub content_kinds: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub preprocessors: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub actions: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub postprocessors: Vec<String>,
    #[serde(default = "default_automation_source_app_mode")]
    pub source_app_mode: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub allowed_bundle_identifiers: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub denied_bundle_identifiers: Vec<String>,
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
    RiskClassifier {
        field: PolicyEvidenceField,
        threshold: u8,
        high_risk_reason_code: PolicyReasonCode,
        missing_reason_code: PolicyReasonCode,
    },
    WaitStep(PolicyWaitStep),
    EventWait(PolicyEventWait),
    Handoff(PolicyHandoffStep),
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
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyWorkflowEntry {
    pub workflow_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyActionStep {
    pub action_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyWaitStep {
    pub wait: PolicyWaitCondition,
    pub resume_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PolicyWaitCondition {
    Timer { duration_seconds: u64 },
    Event { event_key: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyRuntimeBoundary {
    pub node_id: String,
    pub resume_key: String,
    pub wait: PolicyWaitCondition,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyEventWait {
    pub event_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyHandoffStep {
    pub handoff_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyFinishNode {
    pub decision: PolicyGraphDecision,
    pub reason_code: PolicyReasonCode,
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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyEvidenceCheck {
    pub field: PolicyEvidenceField,
    pub pass: PolicyEvidencePredicate,
    pub fail_reason_code: PolicyReasonCode,
    pub missing_reason_code: PolicyReasonCode,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyGraphEdge {
    pub id: String,
    pub from_node: String,
    pub from_port: String,
    pub to_node: String,
    pub to_port: String,
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
    RiskHigh,
    RiskLowOrEqual,
    RiskMissing,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyGraphGroup {
    pub id: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default)]
    pub frame: PolicyCanvasRect,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub node_ids: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyGraphLayout {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub nodes: Vec<PolicyGraphNodeLayout>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyGraphNodeLayout {
    pub node_id: String,
    pub x: i32,
    pub y: i32,
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
    pub id: String,
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

    fn auto_merge_risk_threshold(&self) -> u8 {
        self.nodes
            .iter()
            .find_map(|node| match node.kind {
                PolicyGraphNodeKind::RiskClassifier { threshold, .. } => Some(threshold),
                _ => None,
            })
            .unwrap_or(DEFAULT_AUTO_MERGE_RISK_THRESHOLD)
    }
}

impl PolicyGraphValidationReport {
    #[must_use]
    pub fn is_valid(&self) -> bool {
        self.issues.is_empty()
    }
}

fn default_automation_enabled() -> bool {
    true
}

fn default_automation_source_app_mode() -> String {
    "allExceptDenied".to_string()
}
