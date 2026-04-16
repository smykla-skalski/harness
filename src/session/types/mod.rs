mod agents;
mod events;
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
    AgentPersona, AgentRegistration, AgentStatus, PendingLeaderTransfer, PersonaSymbol, SessionRole,
};
pub use events::{SessionLogEntry, SessionSignalRecord, SessionSignalStatus, SessionTransition};
pub use policy::{AutoPromotionPolicy, LeaderJoinPolicy, LeaderRecoveryPolicy, SessionPolicy};
pub use state::{
    CONTROL_PLANE_ACTOR_ID, CURRENT_VERSION, SessionMetrics, SessionState, SessionStatus,
};
pub use tasks::{
    TaskCheckpoint, TaskCheckpointSummary, TaskNote, TaskQueuePolicy, TaskSeverity, TaskSource,
    TaskStatus, WorkItem,
};
