mod agents;
#[doc(hidden)]
pub mod crosswalk;
mod events;
mod identity;
mod policy;
mod state;
mod tasks;

#[cfg(test)]
mod agent_tests;
#[cfg(test)]
mod event_tests;
#[cfg(test)]
mod state_tests;
#[cfg(test)]
mod task_tests;
#[cfg(test)]
mod test_support;

pub use agents::{
    AgentPersona, AgentRegistration, AgentRegistrationWire, AgentStatus, ManagedAgentKind,
    ManagedAgentRef, PendingLeaderTransfer, PersonaSymbol, SessionRole,
};
pub use events::{SessionLogEntry, SessionSignalRecord, SessionSignalStatus, SessionTransition};
pub use identity::{
    AgentDescriptorId, HarnessSessionId, ManagedAgentId, RuntimeSessionId, SessionAgentId,
};
pub use policy::{AutoPromotionPolicy, LeaderJoinPolicy, LeaderRecoveryPolicy, SessionPolicy};
#[doc(hidden)]
pub use state::is_control_plane_actor_id;
pub use state::{
    CONTROL_PLANE_ACTOR_ID, CURRENT_VERSION, SessionMetrics, SessionState, SessionStatus,
};
pub use tasks::{
    ARBITRATION_BLOCKED_REASON, ArbitrationOutcome, AwaitingReview, Review, ReviewClaim,
    ReviewConsensus, ReviewPoint, ReviewPointState, ReviewVerdict, ReviewerEntry, TaskCheckpoint,
    TaskCheckpointSummary, TaskNote, TaskQueuePolicy, TaskSeverity, TaskSource, TaskStatus,
    WorkItem,
};
