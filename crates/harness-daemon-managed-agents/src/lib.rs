//! Ports the managed-terminal-agent manager needs from `harness-daemon`,
//! ahead of the manager itself moving into this crate.
//!
//! `harness-daemon` implements every trait here for its own concrete
//! database handle types. This crate never depends on `harness-daemon`, so
//! it stays the dependency direction that lets the manager eventually
//! relocate here without a cycle.

mod kill_switch;
mod storage;

pub use kill_switch::AgentTuiKillSwitch;
pub use storage::AsyncAgentTuiStorage;
