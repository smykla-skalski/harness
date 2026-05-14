use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty};

use super::{
    PolicyAction, PolicyDecision, PolicyGate, PolicyGraph, PolicyGraphMode,
    PolicyGraphValidationReport, PolicyInput,
};

const POLICY_PIPELINE_FILE: &str = "policy-pipeline-v2.json";
const POLICY_PIPELINE_SIMULATION_FILE: &str = "policy-pipeline-v2-simulation.json";

#[derive(Debug, Clone)]
pub struct GraphPolicyGate {
    document: PolicyGraph,
}

impl GraphPolicyGate {
    #[must_use]
    pub fn new(document: PolicyGraph) -> Self {
        Self { document }
    }
}

impl PolicyGate for GraphPolicyGate {
    fn evaluate(&self, input: &PolicyInput) -> PolicyDecision {
        self.document.simulate(input).decision
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyPipelineSaveResponse {
    pub document: PolicyGraph,
    pub validation: PolicyGraphValidationReport,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PolicyPipelinePromoteRequest {
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyPipelinePromoteResponse {
    pub document: PolicyGraph,
    pub trace_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyPipelineSimulatedDecision {
    pub action: PolicyAction,
    pub decision: PolicyDecision,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub visited_node_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub policy_trace_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyPipelineSimulationResult {
    pub revision: u64,
    pub trace_id: String,
    pub simulated_at: String,
    pub succeeded: bool,
    pub validation: PolicyGraphValidationReport,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub decisions: Vec<PolicyPipelineSimulatedDecision>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub policy_trace_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyPipelineAuditSummary {
    pub active_revision: u64,
    pub mode: PolicyGraphMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest_trace_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest_simulation: Option<PolicyPipelineSimulationResult>,
    pub validation: PolicyGraphValidationReport,
}

#[derive(Debug, Clone)]
pub struct PolicyPipelineStore {
    root: PathBuf,
}

impl PolicyPipelineStore {
    #[must_use]
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    /// Load durable policy graph state, seeding the V2 default when absent.
    ///
    /// # Errors
    /// Returns `CliError` when graph state cannot be read or seeded.
    pub fn load_or_seed(&self) -> Result<PolicyGraph, CliError> {
        let path = self.document_path();
        if path.exists() {
            return read_json_typed(&path);
        }
        let document = PolicyGraph::seeded_v2();
        write_json_pretty(&path, &document)?;
        Ok(document)
    }

    /// Persist a draft policy graph.
    ///
    /// # Errors
    /// Returns `CliError` when graph state cannot be written.
    pub fn save_draft(
        &self,
        mut document: PolicyGraph,
    ) -> Result<PolicyPipelineSaveResponse, CliError> {
        let current_revision = self
            .load_or_seed()
            .map_or(document.revision, |current| current.revision);
        document.revision = current_revision.max(document.revision).saturating_add(1);
        document.mode = PolicyGraphMode::Draft;
        let validation = document.validate();
        write_json_pretty(&self.document_path(), &document)?;
        Ok(PolicyPipelineSaveResponse {
            document,
            validation,
        })
    }

    /// Simulate a draft or current policy graph.
    ///
    /// # Errors
    /// Returns `CliError` when current graph state cannot be loaded.
    pub fn simulate(
        &self,
        document: Option<PolicyGraph>,
    ) -> Result<PolicyPipelineSimulationResult, CliError> {
        let document = document
            .unwrap_or(self.load_or_seed()?)
            .with_mode(PolicyGraphMode::DryRun);
        let validation = document.validate();
        let decisions = simulation_inputs()
            .into_iter()
            .map(|input| {
                let simulation = document.simulate(&input);
                PolicyPipelineSimulatedDecision {
                    action: input.action,
                    decision: simulation.decision,
                    visited_node_ids: simulation.visited_node_ids,
                    policy_trace_ids: simulation.policy_trace_ids,
                }
            })
            .collect();
        let result = PolicyPipelineSimulationResult {
            revision: document.revision,
            trace_id: new_trace_id(),
            simulated_at: chrono::Utc::now().to_rfc3339(),
            succeeded: validation.is_valid(),
            validation,
            decisions,
            policy_trace_ids: document.policy_trace_ids,
        };
        write_json_pretty(&self.simulation_path(), &result)?;
        Ok(result)
    }

    /// Promote the current policy graph to enforced mode.
    ///
    /// # Errors
    /// Returns `CliError` when revision preconditions fail or persistence fails.
    pub fn promote(
        &self,
        request: &PolicyPipelinePromoteRequest,
    ) -> Result<PolicyPipelinePromoteResponse, CliError> {
        let document = self.load_or_seed()?;
        if document.revision != request.revision {
            return Err(CliErrorKind::invalid_transition(format!(
                "policy graph revision {} cannot promote request revision {}",
                document.revision, request.revision
            ))
            .into());
        }
        let latest_simulation = self.latest_simulation()?;
        if latest_simulation.as_ref().is_none_or(|simulation| {
            !simulation.succeeded || simulation.revision != request.revision
        }) {
            return Err(CliErrorKind::invalid_transition(format!(
                "policy graph revision {} requires a successful exact simulation before promotion",
                request.revision
            ))
            .into());
        }
        let document = document
            .promoted(PolicyGraphMode::Enforced, request.revision)
            .map_err(|report| validation_error(&report))?;
        write_json_pretty(&self.document_path(), &document)?;
        Ok(PolicyPipelinePromoteResponse {
            document,
            trace_id: new_trace_id(),
        })
    }

    /// Summarize durable policy graph state.
    ///
    /// # Errors
    /// Returns `CliError` when current graph state cannot be loaded.
    pub fn audit_summary(&self) -> Result<PolicyPipelineAuditSummary, CliError> {
        let document = self.load_or_seed()?;
        let latest_simulation = self.latest_simulation()?;
        Ok(PolicyPipelineAuditSummary {
            active_revision: document.revision,
            mode: document.mode,
            latest_trace_id: latest_simulation
                .as_ref()
                .map(|simulation| simulation.trace_id.clone()),
            latest_simulation,
            validation: document.validate(),
        })
    }

    fn document_path(&self) -> PathBuf {
        self.root.join(POLICY_PIPELINE_FILE)
    }

    fn simulation_path(&self) -> PathBuf {
        self.root.join(POLICY_PIPELINE_SIMULATION_FILE)
    }

    fn latest_simulation(&self) -> Result<Option<PolicyPipelineSimulationResult>, CliError> {
        let path = self.simulation_path();
        if path.exists() {
            return read_json_typed(&path).map(Some);
        }
        Ok(None)
    }
}

fn validation_error(report: &PolicyGraphValidationReport) -> CliError {
    CliErrorKind::invalid_transition(format!(
        "policy graph validation failed with {} issue(s)",
        report.issues.len()
    ))
    .into()
}

fn new_trace_id() -> String {
    format!("policy-pipeline-{}", Uuid::new_v4().simple())
}

fn simulation_inputs() -> Vec<PolicyInput> {
    use crate::task_board::policy::{
        DEFAULT_AUTO_MERGE_RISK_THRESHOLD, PolicyEvidence, PolicySubject,
    };

    let default_subject = PolicySubject::default();
    let merge_evidence = PolicyEvidence {
        checks_green: Some(true),
        branch_protection_allows_merge: Some(true),
        reviewer_verdict_approved: Some(true),
        unresolved_requested_changes: Some(0),
        protected_path_touched: Some(false),
        risk_score: Some(DEFAULT_AUTO_MERGE_RISK_THRESHOLD),
    };
    all_actions()
        .into_iter()
        .map(|action| PolicyInput {
            action,
            subject: default_subject.clone(),
            evidence: if action == PolicyAction::MergePr {
                merge_evidence.clone()
            } else {
                PolicyEvidence::default()
            },
        })
        .collect()
}

fn all_actions() -> Vec<PolicyAction> {
    vec![
        PolicyAction::Sync,
        PolicyAction::Triage,
        PolicyAction::Plan,
        PolicyAction::SpawnAgent,
        PolicyAction::MutateRepo,
        PolicyAction::PushBranch,
        PolicyAction::OpenPr,
        PolicyAction::SubmitReview,
        PolicyAction::MergePr,
        PolicyAction::DeleteWorktree,
        PolicyAction::StopAgent,
        PolicyAction::AccessSecret,
        PolicyAction::DestructiveFs,
    ]
}
