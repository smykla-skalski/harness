use std::borrow::Cow;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[non_exhaustive]
pub enum WorkflowError {
    #[error("invalid runner state transition: {detail}")]
    InvalidTransition { detail: Cow<'static, str> },
    #[error("{detail}")]
    WorkflowIo { detail: Cow<'static, str> },
    #[error("{detail}")]
    WorkflowParse { detail: Cow<'static, str> },
    #[error("unsupported workflow schema version: {detail}")]
    WorkflowVersion { detail: Cow<'static, str> },
    #[error("workflow state changed concurrently: {detail}")]
    ConcurrentModification { detail: Cow<'static, str> },
    #[error("serialization failed: {detail}")]
    WorkflowSerialize { detail: Cow<'static, str> },
    #[error("session not active: {detail}")]
    SessionNotActive { detail: Cow<'static, str> },
    #[error("session permission denied: {detail}")]
    SessionPermissionDenied { detail: Cow<'static, str> },
    #[error("session agent conflict: {detail}")]
    SessionAgentConflict { detail: Cow<'static, str> },
    #[error("invalid project directory (no file_name component): {path}")]
    InvalidProjectDir { path: Cow<'static, str> },
    #[error("ACP managed-agent routes are disabled")]
    AcpDisabled,
    #[error("session scope denied: {detail}")]
    SessionScopeDenied { detail: Cow<'static, str> },
    #[error("item not dispatchable: {detail}")]
    ItemNotDispatchable { detail: Cow<'static, str> },
    #[error("task-board lane capacity exceeded: {detail}")]
    TaskBoardLaneCapacity { detail: Cow<'static, str> },
    /// A held step-mode dispatch is missing or no longer claimable when the
    /// worker delivery tried to claim it. Distinct from a session conflict so
    /// callers see the real reason (already delivered, cancelled, or never
    /// reserved) instead of a generic agent contention message.
    #[error("{detail}")]
    TaskBoardDeliveryNotHeld { detail: Cow<'static, str> },
}

impl WorkflowError {
    #[must_use]
    pub fn code(&self) -> &'static str {
        match self {
            Self::InvalidTransition { .. } => "KSRCLI084",
            Self::WorkflowIo { .. } => "WORKFLOW_IO",
            Self::WorkflowParse { .. } => "WORKFLOW_PARSE",
            Self::WorkflowVersion { .. } => "WORKFLOW_VERSION",
            Self::ConcurrentModification { .. } => "WORKFLOW_CONCURRENT",
            Self::WorkflowSerialize { .. } => "WORKFLOW_SERIALIZE",
            Self::SessionNotActive { .. } => "KSRCLI090",
            Self::SessionPermissionDenied { .. } => "KSRCLI091",
            Self::SessionAgentConflict { .. } => "KSRCLI092",
            Self::InvalidProjectDir { .. } => "KSRCLI093",
            Self::AcpDisabled => "ACP_DISABLED",
            Self::SessionScopeDenied { .. } => "SESSION_SCOPE_DENIED",
            Self::ItemNotDispatchable { .. } => "KSRCLI094",
            Self::TaskBoardLaneCapacity { .. } => "TASK_BOARD_LANE_CAPACITY",
            Self::TaskBoardDeliveryNotHeld { .. } => "TASK_BOARD_DELIVERY_NOT_HELD",
        }
    }

    #[must_use]
    pub const fn exit_code() -> i32 {
        5
    }

    #[must_use]
    pub fn invalid_transition(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::InvalidTransition {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn workflow_io(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::WorkflowIo {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn workflow_parse(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::WorkflowParse {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn workflow_version(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::WorkflowVersion {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn concurrent_modification(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::ConcurrentModification {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn workflow_serialize(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::WorkflowSerialize {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn session_not_active(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::SessionNotActive {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn session_permission_denied(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::SessionPermissionDenied {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn session_agent_conflict(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::SessionAgentConflict {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn invalid_project_dir(path: impl Into<Cow<'static, str>>) -> Self {
        Self::InvalidProjectDir { path: path.into() }
    }

    #[must_use]
    pub fn acp_disabled() -> Self {
        Self::AcpDisabled
    }

    #[must_use]
    pub fn session_scope_denied(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::SessionScopeDenied {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn item_not_dispatchable(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::ItemNotDispatchable {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn task_board_lane_capacity(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::TaskBoardLaneCapacity {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn task_board_delivery_not_held(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::TaskBoardDeliveryNotHeld {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn hint() -> Option<String> {
        None
    }
}
