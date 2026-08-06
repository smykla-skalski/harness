use harness_protocol::daemon::summaries::{
    AgentWorkspaceLivenessStatus, AgentWorkspaceManagedIdentity, AgentWorkspaceMembershipStatus,
    AgentWorkspaceRuntimeLifecycle, AgentWorkspaceTeamConflict, AgentWorkspaceTeamConflictKind,
};
use harness_protocol::session::{ManagedAgentKind, SessionRole};

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum MemberKey {
    Managed {
        kind: String,
        id: String,
    },
    Legacy {
        session_id: String,
        agent_id: String,
    },
}

#[derive(Debug, Clone)]
pub(super) struct MemberProvenancePlan {
    pub source_session_id: String,
    pub source_agent_id: String,
    pub source_digest: String,
    pub is_selected: bool,
}

#[derive(Debug, Clone)]
pub(super) struct MemberPlan {
    pub member_id: String,
    pub runtime_kind: String,
    pub managed_agent_kind: Option<String>,
    pub managed_agent_id: Option<String>,
    pub display_name: String,
    pub role: Option<String>,
    pub membership_status: AgentWorkspaceMembershipStatus,
    pub liveness_status: AgentWorkspaceLivenessStatus,
    pub runtime_session_id: Option<String>,
    pub assignment_id: Option<String>,
    pub runtime_lifecycle: AgentWorkspaceRuntimeLifecycle,
    pub runtime_evidence: String,
    pub source_session_id: Option<String>,
    pub source_agent_id: Option<String>,
    pub source_digest: String,
    pub membership_source_digest: String,
    pub runtime_source_digest: String,
    pub membership_override_source_digest: Option<String>,
    pub runtime_override_source_digest: Option<String>,
    pub joined_at: Option<String>,
    pub last_activity_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub provenance: Vec<MemberProvenancePlan>,
}

#[derive(Debug)]
pub(super) struct TeamPlan {
    pub workspace_id: String,
    pub authority: String,
    pub selected_legacy_session_id: Option<String>,
    pub selected_lifecycle: Option<String>,
    pub leader_member_id: Option<String>,
    pub source_revision: i64,
    pub created_at: Option<String>,
    pub updated_at: String,
    pub members: Vec<MemberPlan>,
}

pub(super) fn managed_kind(value: &str) -> Result<ManagedAgentKind, String> {
    match value {
        "tui" => Ok(ManagedAgentKind::Tui),
        "acp" => Ok(ManagedAgentKind::Acp),
        "codex" => Ok(ManagedAgentKind::Codex),
        _ => Err(format!("unknown managed agent kind '{value}'")),
    }
}

pub(super) fn role(value: &str) -> Result<SessionRole, String> {
    match value {
        "leader" => Ok(SessionRole::Leader),
        "observer" => Ok(SessionRole::Observer),
        "worker" => Ok(SessionRole::Worker),
        "reviewer" => Ok(SessionRole::Reviewer),
        "improver" => Ok(SessionRole::Improver),
        _ => Err(format!("unknown agent role '{value}'")),
    }
}

pub(super) fn managed_identity(
    kind: Option<&str>,
    id: Option<&str>,
) -> Result<Option<AgentWorkspaceManagedIdentity>, String> {
    match (kind, id) {
        (None, None) => Ok(None),
        (Some(kind), Some(id)) if !id.is_empty() => Ok(Some(AgentWorkspaceManagedIdentity {
            kind: managed_kind(kind)?,
            managed_agent_id: id.to_string(),
        })),
        _ => Err("managed agent kind and identifier must be present together".to_string()),
    }
}

pub(super) fn identity_conflict(
    legacy_session_ids: Vec<String>,
    kind: &str,
    id: &str,
    detail: impl Into<String>,
) -> AgentWorkspaceTeamConflict {
    AgentWorkspaceTeamConflict {
        kind: AgentWorkspaceTeamConflictKind::IdentityCollision,
        legacy_session_ids,
        managed_identity: managed_identity(Some(kind), Some(id)).ok().flatten(),
        detail: detail.into(),
    }
}

pub(super) fn malformed_conflict(
    legacy_session_ids: Vec<String>,
    detail: impl Into<String>,
) -> AgentWorkspaceTeamConflict {
    AgentWorkspaceTeamConflict {
        kind: AgentWorkspaceTeamConflictKind::MalformedSource,
        legacy_session_ids,
        managed_identity: None,
        detail: detail.into(),
    }
}
