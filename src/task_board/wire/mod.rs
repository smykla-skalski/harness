//! Wire contracts for the task-board domain.
//!
//! These describe task-board requests and responses, so they carry the
//! domain's own types and belong beside it. The daemon re-exports them from
//! `crate::daemon::protocol`; nothing here may reach back into the daemon.

mod policy_transfer;
mod task_board;
mod task_board_automation;
mod task_board_item_requests;
mod task_board_spawn_gate;
mod task_board_steps;
mod task_board_triage;
mod task_board_triage_escalation;
mod task_board_triage_rules;

pub use policy_transfer::*;
pub use task_board::*;
pub use task_board_automation::*;
pub use task_board_item_requests::*;
pub use task_board_spawn_gate::*;
pub use task_board_steps::*;
pub use task_board_triage::*;
pub use task_board_triage_escalation::*;
pub use task_board_triage_rules::*;
