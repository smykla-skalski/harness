use harness_session::index::DiscoveredProject;

/// A checkout the daemon created for a durable workspace, and the workspace
/// identity it belongs to.
///
/// `project` is discovered from the new checkout itself rather than from the
/// origin, so the workspace this provisions is the one the worker actually runs
/// in - a second dispatch against the same origin gets its own workspace
/// instead of colliding with the first.
#[derive(Debug, Clone)]
pub struct WorkspaceCheckoutRequest {
    pub daemon_id: String,
    pub project: DiscoveredProject,
    pub working_copy_id: String,
    pub origin_path: String,
    pub project_name: String,
    pub worktree_path: String,
    pub branch_ref: String,
}

/// The owners a provisioned checkout hands back to dispatch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProvisionedWorkspaceCheckout {
    pub workspace_id: String,
    pub working_copy_id: String,
    pub worktree_path: String,
    pub branch_ref: String,
}

/// A recorded checkout, read back by recovery and compensation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentWorkingCopy {
    pub working_copy_id: String,
    pub workspace_id: String,
    pub origin_path: String,
    pub project_name: String,
    pub worktree_path: String,
    pub branch_ref: String,
    pub released: bool,
}

/// The managed runtime a workspace member wraps.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkspaceManagedAgentKind {
    Terminal,
    Codex,
}

impl WorkspaceManagedAgentKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Terminal => "tui",
            Self::Codex => "codex",
        }
    }
}

/// One managed worker joining a workspace team at start.
#[derive(Debug, Clone)]
pub struct WorkspaceMemberRegistration {
    pub workspace_id: String,
    pub kind: WorkspaceManagedAgentKind,
    pub managed_agent_id: String,
    pub runtime_kind: String,
    pub display_name: String,
    pub assignment_id: Option<String>,
}

impl WorkspaceMemberRegistration {
    /// The member id the v64 backfill mints for a managed identity, reproduced
    /// here so a worker started fresh and the same worker seen later through
    /// reconciliation resolve to one row rather than two.
    #[must_use]
    pub fn member_id(&self) -> String {
        format!(
            "member-m-{}-{}",
            hex::encode(self.kind.as_str()),
            hex::encode(&self.managed_agent_id)
        )
    }
}
