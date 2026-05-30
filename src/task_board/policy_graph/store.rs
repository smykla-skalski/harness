use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

use super::{
    PolicyAction, PolicyCanvasRecord, PolicyCanvasWorkspace, PolicyCanvasWorkspaceStore,
    PolicyDecision, PolicyGate, PolicyGraph, PolicyGraphMode, PolicyGraphValidationReport,
    PolicyInput,
};

use super::store_canvas::{new_trace_id, simulation_inputs, validation_error};

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
    #[serde(default)]
    pub persisted: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PolicyPipelinePromoteRequest {
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub canvas_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyPipelinePromoteResponse {
    pub document: PolicyGraph,
    pub trace_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PolicyPipelineSimulatedDecision {
    pub action: PolicyAction,
    pub decision: PolicyDecision,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub visited_node_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub policy_trace_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub boundaries: Vec<super::PolicyRuntimeBoundary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
    #[serde(default)]
    pub has_runtime_boundaries: bool,
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

    /// Load durable policy canvas workspace state, migrating the legacy
    /// single-pipeline files when needed.
    ///
    /// # Errors
    /// Returns `CliError` when workspace state cannot be read or seeded.
    pub fn load_workspace_or_seed(&self) -> Result<PolicyCanvasWorkspace, CliError> {
        self.workspace_store().load_or_seed()
    }

    /// Load the active durable policy graph state.
    ///
    /// # Errors
    /// Returns `CliError` when graph state cannot be read or seeded.
    pub fn load_or_seed(&self) -> Result<PolicyGraph, CliError> {
        self.load_or_seed_for_active_canvas(None)
    }

    /// Load the active durable policy graph state while guarding against stale
    /// canvas selections.
    ///
    /// # Errors
    /// Returns `CliError` when graph state cannot be read or seeded.
    pub fn load_or_seed_for_active_canvas(
        &self,
        expected_canvas_id: Option<&str>,
    ) -> Result<PolicyGraph, CliError> {
        let workspace = self.load_workspace_or_seed()?;
        Ok(
            Self::active_canvas_for_request(&workspace, expected_canvas_id)?
                .document
                .clone(),
        )
    }

    /// Persist a draft policy graph.
    ///
    /// `if_revision` is a compare-and-swap precondition: when non-zero, it must
    /// match the currently persisted revision or the save is rejected with
    /// `concurrent_modification`. A zero value preserves the legacy unchecked
    /// behavior so older callers keep working.
    ///
    /// The draft is written only when `document.validate().is_valid()`.
    /// An invalid draft returns a response with `persisted: false`, the
    /// unwritten document, and the validation report; on-disk state stays
    /// unchanged.
    ///
    /// # Errors
    /// Returns `CliError` when the revision precondition fails or graph state
    /// cannot be written.
    pub fn save_draft(
        &self,
        document: PolicyGraph,
        if_revision: u64,
    ) -> Result<PolicyPipelineSaveResponse, CliError> {
        self.save_draft_for_active_canvas(document, if_revision, None)
    }

    /// Persist a draft policy graph for the current active canvas, rejecting a
    /// stale `expected_canvas_id` when the selection has changed.
    ///
    /// # Errors
    /// Returns `CliError` when the revision precondition fails or graph state
    /// cannot be written.
    pub fn save_draft_for_active_canvas(
        &self,
        mut document: PolicyGraph,
        if_revision: u64,
        expected_canvas_id: Option<&str>,
    ) -> Result<PolicyPipelineSaveResponse, CliError> {
        let workspace = self.load_workspace_or_seed()?;
        let current_revision = Self::active_canvas_for_request(&workspace, expected_canvas_id)?
            .document
            .revision;
        if if_revision != 0 && current_revision != if_revision {
            return Err(CliErrorKind::concurrent_modification(format!(
                "policy graph draft revision conflict: expected {if_revision}, found {current_revision}"
            ))
            .into());
        }
        document.mode = PolicyGraphMode::Draft;
        let validation = document.validate();
        if !validation.is_valid() {
            return Ok(PolicyPipelineSaveResponse {
                document,
                validation,
                persisted: false,
            });
        }
        document.revision = current_revision.max(document.revision).saturating_add(1);
        let persisted_document = document.clone();
        self.workspace_store().update(|workspace| {
            let canvas = Self::active_canvas_mut_for_request(workspace, expected_canvas_id)?;
            canvas.document = persisted_document.clone();
            canvas.latest_simulation = None;
            canvas.touch();
            Ok(())
        })?;
        Ok(PolicyPipelineSaveResponse {
            document,
            validation,
            persisted: true,
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
        self.simulate_for_active_canvas(document, None)
    }

    /// Simulate the current active policy graph, rejecting a stale
    /// `expected_canvas_id` when the selection has changed.
    ///
    /// # Errors
    /// Returns `CliError` when current graph state cannot be loaded.
    pub fn simulate_for_active_canvas(
        &self,
        document: Option<PolicyGraph>,
        expected_canvas_id: Option<&str>,
    ) -> Result<PolicyPipelineSimulationResult, CliError> {
        let workspace = self.load_workspace_or_seed()?;
        let base_document = if let Some(document) = document {
            document
        } else {
            Self::active_canvas_for_request(&workspace, expected_canvas_id)?
                .document
                .clone()
        };
        let document = base_document.with_mode(PolicyGraphMode::DryRun);
        let validation = document.validate();
        let decisions: Vec<_> = simulation_inputs()
            .into_iter()
            .map(|input| {
                let simulation = document.simulate(&input);
                PolicyPipelineSimulatedDecision {
                    action: input.action,
                    decision: simulation.decision,
                    visited_node_ids: simulation.visited_node_ids,
                    policy_trace_ids: simulation.policy_trace_ids,
                    boundaries: simulation.boundaries,
                }
            })
            .collect();
        let has_runtime_boundaries = decisions
            .iter()
            .any(|decision| !decision.boundaries.is_empty());
        let result = PolicyPipelineSimulationResult {
            revision: document.revision,
            trace_id: new_trace_id(),
            simulated_at: chrono::Utc::now().to_rfc3339(),
            succeeded: validation.is_valid(),
            validation,
            decisions,
            policy_trace_ids: document.policy_trace_ids,
            has_runtime_boundaries,
        };
        let persisted_result = result.clone();
        self.workspace_store().update(|workspace| {
            let canvas = Self::active_canvas_mut_for_request(workspace, expected_canvas_id)?;
            canvas.latest_simulation = Some(persisted_result.clone());
            canvas.touch();
            Ok(())
        })?;
        Ok(result)
    }

    /// Promote the current policy graph to enforced mode.
    ///
    /// The `revision` field on the request acts as a compare-and-swap
    /// precondition. The promotion fails with `concurrent_modification` when
    /// the on-disk revision has moved past the request's expectation.
    ///
    /// # Errors
    /// Returns `CliError` when revision preconditions fail or persistence fails.
    pub fn promote(
        &self,
        request: &PolicyPipelinePromoteRequest,
    ) -> Result<PolicyPipelinePromoteResponse, CliError> {
        let mut response = None;
        self.workspace_store().update(|workspace| {
            let canvas =
                Self::active_canvas_mut_for_request(workspace, request.canvas_id.as_deref())?;
            if canvas.document.revision != request.revision {
                return Err(CliErrorKind::concurrent_modification(format!(
                    "policy graph promote revision conflict: expected {}, found {}",
                    request.revision, canvas.document.revision
                ))
                .into());
            }
            if canvas.latest_simulation.as_ref().is_none_or(|simulation| {
                !simulation.succeeded || simulation.revision != request.revision
            }) {
                return Err(CliErrorKind::invalid_transition(format!(
                    "policy graph revision {} requires a successful exact simulation before promotion",
                    request.revision
                ))
                .into());
            }
            if canvas
                .document
                .nodes
                .iter()
                .any(|node| matches!(node.kind, super::PolicyGraphNodeKind::WaitStep(_)))
                && canvas
                    .latest_simulation
                    .as_ref()
                    .is_some_and(|simulation| !simulation.has_runtime_boundaries)
            {
                return Err(CliErrorKind::invalid_transition(format!(
                    "policy graph revision {} requires runtime boundary simulation metadata before promotion",
                    request.revision
                ))
                .into());
            }
            let document = canvas
                .document
                .clone()
                .promoted(PolicyGraphMode::Enforced, request.revision)
                .map_err(|report| validation_error(&report))?;
            canvas.document = document.clone();
            canvas.touch();
            response = Some(PolicyPipelinePromoteResponse {
                document,
                trace_id: new_trace_id(),
            });
            Ok(())
        })?;
        response.ok_or_else(|| {
            CliErrorKind::workflow_io("policy canvas promotion did not produce a response").into()
        })
    }

    /// Summarize durable policy graph state.
    ///
    /// # Errors
    /// Returns `CliError` when current graph state cannot be loaded.
    pub fn audit_summary(&self) -> Result<PolicyPipelineAuditSummary, CliError> {
        self.audit_summary_for_active_canvas(None)
    }

    /// Summarize active durable policy graph state while guarding against stale
    /// canvas selections.
    ///
    /// # Errors
    /// Returns `CliError` when current graph state cannot be loaded.
    pub fn audit_summary_for_active_canvas(
        &self,
        expected_canvas_id: Option<&str>,
    ) -> Result<PolicyPipelineAuditSummary, CliError> {
        let workspace = self.load_workspace_or_seed()?;
        let canvas = Self::active_canvas_for_request(&workspace, expected_canvas_id)?;
        let latest_simulation = canvas.latest_simulation.clone();
        Ok(PolicyPipelineAuditSummary {
            active_revision: canvas.document.revision,
            mode: canvas.document.mode,
            latest_trace_id: latest_simulation
                .as_ref()
                .map(|simulation| simulation.trace_id.clone()),
            latest_simulation,
            validation: canvas.document.validate(),
        })
    }

    pub(super) fn workspace_store(&self) -> PolicyCanvasWorkspaceStore {
        PolicyCanvasWorkspaceStore::new(self.root.clone())
    }

    fn active_canvas_for_request<'a>(
        workspace: &'a PolicyCanvasWorkspace,
        expected_canvas_id: Option<&str>,
    ) -> Result<&'a PolicyCanvasRecord, CliError> {
        Self::ensure_active_canvas_matches(workspace, expected_canvas_id)?;
        Self::active_canvas(workspace)
    }

    fn active_canvas_mut_for_request<'a>(
        workspace: &'a mut PolicyCanvasWorkspace,
        expected_canvas_id: Option<&str>,
    ) -> Result<&'a mut PolicyCanvasRecord, CliError> {
        Self::ensure_active_canvas_matches(workspace, expected_canvas_id)?;
        Self::active_canvas_mut(workspace)
    }

    fn ensure_active_canvas_matches(
        workspace: &PolicyCanvasWorkspace,
        expected_canvas_id: Option<&str>,
    ) -> Result<(), CliError> {
        if let Some(expected_canvas_id) = expected_canvas_id
            && workspace.active_canvas_id != expected_canvas_id
        {
            return Err(CliErrorKind::concurrent_modification(format!(
                "policy canvas selection changed: expected '{expected_canvas_id}', found '{}'",
                workspace.active_canvas_id
            ))
            .into());
        }
        Ok(())
    }

    fn active_canvas(workspace: &PolicyCanvasWorkspace) -> Result<&PolicyCanvasRecord, CliError> {
        workspace.active_canvas().ok_or_else(|| {
            CliErrorKind::workflow_parse(format!(
                "policy canvas workspace missing active canvas '{}'",
                workspace.active_canvas_id
            ))
            .into()
        })
    }

    fn active_canvas_mut(
        workspace: &mut PolicyCanvasWorkspace,
    ) -> Result<&mut PolicyCanvasRecord, CliError> {
        let active_canvas_id = workspace.active_canvas_id.clone();
        workspace.active_canvas_mut().ok_or_else(|| {
            CliErrorKind::workflow_parse(format!(
                "policy canvas workspace missing active canvas '{active_canvas_id}'"
            ))
            .into()
        })
    }
}
