use serde::{Deserialize, Serialize};

use crate::task_board::planning::PlanningTransition;
use crate::task_board::types::TaskBoardWorkflowState;
use crate::task_board::{
    AgentMode, DispatchExecutionSummary, ExternalProvider, ExternalRef, ExternalSyncConflictPolicy,
    ExternalSyncDirection, Machine, PlanningState, PolicyGraphMode, PolicyPipelineAuditSummary,
    PolicyPipelineDocument, PolicyPipelinePromoteRequest, PolicyPipelinePromoteResponse,
    PolicyPipelineSaveResponse, PolicyPipelineSimulationResult, TaskBoardAuditSummary,
    TaskBoardEvaluationSummary, TaskBoardGitIdentityDefaults, TaskBoardItem,
    TaskBoardMachineSummary, TaskBoardPriority, TaskBoardProjectSummary, TaskBoardStatus,
    TaskBoardSyncSummary,
};

pub use crate::task_board::{
    TaskBoardGitHubTokensSyncRequest,
    TaskBoardGitHubTokensSyncResponse as TaskBoardGitHubTokensSyncOutcome,
    TaskBoardGitRuntimeConfig, TaskBoardOpenRouterTokenSyncRequest,
    TaskBoardOpenRouterTokenSyncResponse as TaskBoardOpenRouterTokenSyncOutcome,
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorSettings,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardOrchestratorStatus,
    TaskBoardTodoistTokenSyncRequest,
    TaskBoardTodoistTokenSyncResponse as TaskBoardTodoistTokenSyncOutcome,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardCreateItemRequest {
    pub title: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub priority: TaskBoardPriority,
    #[serde(default)]
    pub agent_mode: AgentMode,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub target_project_types: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub external_refs: Vec<ExternalRef>,
    #[serde(default)]
    pub planning: PlanningState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow: Option<TaskBoardWorkflowState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work_item_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardListItemsRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardGetItemRequest {
    pub id: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardUpdateItemRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<TaskBoardPriority>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_mode: Option<AgentMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_project_types: Option<Vec<String>>,
    #[serde(default, flatten)]
    pub clear_identity: TaskBoardUpdateIdentityClears,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_refs: Option<Vec<ExternalRef>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub planning: Option<PlanningState>,
    #[serde(default, flatten)]
    pub clear_state: TaskBoardUpdateStateClears,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow: Option<TaskBoardWorkflowState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work_item_id: Option<String>,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct TaskBoardUpdateIdentityClears {
    #[serde(default)]
    pub clear_project_id: bool,
    #[serde(default)]
    pub clear_session_id: bool,
    #[serde(default)]
    pub clear_work_item_id: bool,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct TaskBoardUpdateStateClears {
    #[serde(default)]
    pub clear_planning: bool,
    #[serde(default)]
    pub clear_workflow: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardDeleteItemRequest {
    pub id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardPlanBeginRequest {
    pub id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardPlanSubmitRequest {
    pub id: String,
    pub summary: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardPlanApproveRequest {
    pub id: String,
    pub approved_by: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardPlanRevokeRequest {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardListItemsResponse {
    pub items: Vec<TaskBoardItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardPlanningResponse {
    pub transition: PlanningTransition,
    pub item: TaskBoardItem,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardSyncRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<ExternalProvider>,
    #[serde(default)]
    pub direction: ExternalSyncDirection,
    #[serde(default)]
    pub conflict_policy: ExternalSyncConflictPolicy,
    #[serde(default = "default_sync_dry_run")]
    pub dry_run: bool,
}

impl Default for TaskBoardSyncRequest {
    fn default() -> Self {
        Self {
            status: None,
            provider: None,
            direction: ExternalSyncDirection::default(),
            conflict_policy: ExternalSyncConflictPolicy::default(),
            dry_run: true,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardCatalogRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardDispatchRequest {
    #[serde(default, alias = "id", skip_serializing_if = "Option::is_none")]
    pub item_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
    #[serde(default)]
    pub dry_run: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_dir: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardEvaluateRequest {
    #[serde(default, alias = "id", skip_serializing_if = "Option::is_none")]
    pub item_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
    #[serde(default)]
    pub dry_run: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardAuditRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardPolicyPipelineSaveDraftRequest {
    pub document: PolicyPipelineDocument,
    #[serde(default)]
    pub if_revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub canvas_id: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardPolicyPipelineGetRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub canvas_id: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardPolicyPipelineSimulateRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub document: Option<PolicyPipelineDocument>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub canvas_id: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardPolicyPipelineAuditRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub canvas_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardPolicyCanvasSummary {
    pub canvas_id: String,
    pub title: String,
    pub revision: u64,
    pub mode: PolicyGraphMode,
    pub document: PolicyPipelineDocument,
    pub node_count: usize,
    pub edge_count: usize,
    pub group_count: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest_simulation_trace_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest_simulation_succeeded: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest_simulation_at: Option<String>,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardPolicyCanvasWorkspaceResponse {
    pub schema_version: u32,
    pub active_canvas_id: String,
    #[serde(default)]
    pub canvases: Vec<TaskBoardPolicyCanvasSummary>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardPolicyCanvasCreateRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardPolicyCanvasDuplicateRequest {
    pub canvas_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardPolicyCanvasRenameRequest {
    pub canvas_id: String,
    pub title: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardPolicyCanvasSetActiveRequest {
    pub canvas_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardPolicyCanvasDeleteRequest {
    pub canvas_id: String,
}

pub type TaskBoardSyncResponse = TaskBoardSyncSummary;
pub type TaskBoardProjectsResponse = Vec<TaskBoardProjectSummary>;
pub type TaskBoardMachinesResponse = Vec<TaskBoardMachineSummary>;
pub type TaskBoardHostListResponse = Vec<Machine>;
pub type TaskBoardHostLocalResponse = Machine;
pub type TaskBoardHostSetProjectTypesResponse = Machine;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardHostSetProjectTypesRequest {
    #[serde(default)]
    pub project_types: Vec<String>,
}
pub type TaskBoardDispatchResponse = DispatchExecutionSummary;
pub type TaskBoardEvaluationResponse = TaskBoardEvaluationSummary;
pub type TaskBoardAuditResponse = TaskBoardAuditSummary;
pub type TaskBoardOrchestratorStatusResponse = TaskBoardOrchestratorStatus;
pub type TaskBoardOrchestratorRunOnceResponse = TaskBoardOrchestratorStatus;
pub type TaskBoardOrchestratorSettingsResponse = TaskBoardOrchestratorSettings;
pub type TaskBoardGitRuntimeConfigResponse = TaskBoardGitRuntimeConfig;
pub type TaskBoardGitIdentityDefaultsResponse = TaskBoardGitIdentityDefaults;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardGitSigningVerifyRequest {
    /// Repository slug (`owner/repo`) to scope the verify call to. Omit for
    /// the global profile.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "outcome")]
pub enum TaskBoardGitSigningVerifyResponse {
    /// No signing is configured for the resolved profile.
    Skipped,
    /// A signature was produced from the resolved profile.
    Signed {
        mode: String,
        signature_kind: String,
    },
    /// Signing was attempted but rejected by the current profile or library.
    Failed { message: String },
}
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardGitRuntimeDrainSecretsRequest {}

/// One-shot migration response that returns plaintext task-board git secrets
/// the daemon found on-disk. Callers must persist the payload into their own
/// secure store (e.g. macOS Keychain) immediately; the daemon writes the
/// stripped config back before responding.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TaskBoardGitRuntimeDrainSecretsResponse {
    /// `true` when the on-disk config still contained plaintext secrets and
    /// they were drained into `runtime`. `false` means the on-disk config was
    /// already stripped and `runtime` carries no secret bytes.
    pub drained: bool,
    /// Plaintext runtime config covering all scopes that had secrets. Empty
    /// profiles are omitted via the wire defaults.
    pub runtime: TaskBoardGitRuntimeConfig,
}

pub type TaskBoardGitHubTokensSyncResponse = TaskBoardGitHubTokensSyncOutcome;
pub type TaskBoardTodoistTokenSyncResponse = TaskBoardTodoistTokenSyncOutcome;
pub type TaskBoardOpenRouterTokenSyncResponse = TaskBoardOpenRouterTokenSyncOutcome;
pub type TaskBoardPolicyPipelineResponse = PolicyPipelineDocument;
pub type TaskBoardPolicyPipelineSaveDraftResponse = PolicyPipelineSaveResponse;
pub type TaskBoardPolicyPipelineSimulationResponse = PolicyPipelineSimulationResult;
pub type TaskBoardPolicyPipelinePromoteResponse = PolicyPipelinePromoteResponse;
pub type TaskBoardPolicyPipelineAuditResponse = PolicyPipelineAuditSummary;
pub type TaskBoardPolicyPipelinePromoteRequest = PolicyPipelinePromoteRequest;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardPolicyExportRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub canvas_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardPolicyExportResponse {
    pub canvas_id: String,
    pub title: String,
    pub document: PolicyPipelineDocument,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardPolicyImportRequest {
    pub document: PolicyPipelineDocument,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

pub type TaskBoardPolicyImportResponse = TaskBoardPolicyCanvasWorkspaceResponse;

const fn default_sync_dry_run() -> bool {
    true
}
