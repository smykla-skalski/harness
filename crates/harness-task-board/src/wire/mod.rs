//! Wire contracts for the task-board domain.
//!
//! These describe task-board requests and responses, so they carry the
//! domain's own types and belong beside it. The daemon re-exports them from
//! its own `daemon::protocol` module; nothing here may reach back into the
//! daemon. `task_board_steps`'s `ManagedAgentSnapshot`/
//! `ManagedAgentSnapshotSchema` import comes from `harness_session::wire`
//! directly rather than through a root-crate facade: this crate already
//! depends on `harness-session` for `dispatch`/`evaluation`, and
//! `harness-session` has no dependency back on this crate, so there is no
//! cycle.

mod policy_transfer;
mod task_board;
mod task_board_automation;
mod task_board_item_requests;
mod task_board_orchestrator_status;
mod task_board_spawn_gate;
mod task_board_steps;
mod task_board_triage;
mod task_board_triage_escalation;
mod task_board_triage_rules;
mod task_board_work_item_progress;

pub use policy_transfer::*;
pub use task_board::*;
pub use task_board_automation::*;
pub use task_board_item_requests::*;
pub use task_board_orchestrator_status::*;
pub use task_board_spawn_gate::*;
pub use task_board_steps::*;
pub use task_board_triage::*;
pub use task_board_triage_escalation::*;
pub use task_board_triage_rules::*;
pub use task_board_work_item_progress::*;
