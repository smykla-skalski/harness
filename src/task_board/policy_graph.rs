#![allow(clippy::module_name_repetitions)]

use serde::{Deserialize, Serialize};

use super::policy::{
    BuiltInPolicyGate, DEFAULT_AUTO_MERGE_RISK_THRESHOLD, PolicyAction, PolicyDecision, PolicyGate,
    PolicyInput, PolicyReasonCode, TASK_BOARD_POLICY_VERSION,
};

mod seed;
mod store;
mod validation;

#[cfg(test)]
mod tests;

pub const POLICY_GRAPH_SCHEMA_VERSION: u16 = 2;
pub const POLICY_GRAPH_INITIAL_REVISION: u64 = 1;

pub use store::{
    GraphPolicyGate, PolicyPipelineAuditSummary, PolicyPipelinePromoteRequest,
    PolicyPipelinePromoteResponse, PolicyPipelineSaveResponse, PolicyPipelineSimulatedDecision,
    PolicyPipelineSimulationResult, PolicyPipelineStore,
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
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub input_ports: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub output_ports: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PolicyGraphNodeKind {
    Trigger {
        workflow: String,
    },
    ActionGate {
        actions: Vec<PolicyAction>,
    },
    EvidenceCheck {
        checks: Vec<PolicyEvidenceCheck>,
    },
    RiskClassifier {
        field: PolicyEvidenceField,
        threshold: u8,
        high_risk_reason_code: PolicyReasonCode,
        missing_reason_code: PolicyReasonCode,
    },
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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "predicate", rename_all = "snake_case")]
pub enum PolicyEvidencePredicate {
    IsTrue,
    IsFalse,
    IsZero,
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
    #[serde(default)]
    pub condition: PolicyGraphEdgeCondition,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "condition", rename_all = "snake_case")]
pub enum PolicyGraphEdgeCondition {
    Always,
    ActionIn { actions: Vec<PolicyAction> },
    EvidencePass,
    EvidenceFailure { reason_code: PolicyReasonCode },
    EvidenceConsensus { reason_code: PolicyReasonCode },
    EvidenceMissing,
    RiskHigh,
    RiskLowOrEqual,
    RiskMissing,
}

impl Default for PolicyGraphEdgeCondition {
    fn default() -> Self {
        Self::Always
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyGraphGroup {
    pub id: String,
    pub label: String,
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
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub visited_node_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub policy_trace_ids: Vec<String>,
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
        let decision = BuiltInPolicyGate::new(self.auto_merge_risk_threshold()).evaluate(input);
        PolicyGraphSimulation {
            mode: self.mode,
            visited_node_ids: seed::trace_for(self, input, &decision),
            policy_trace_ids: self.policy_trace_ids.clone(),
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
