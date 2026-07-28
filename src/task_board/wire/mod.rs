//! Wire contracts for the task-board domain.
//!
//! These describe task-board requests and responses, so they carry the
//! domain's own types and belong beside it. The daemon re-exports them from
//! `crate::daemon::protocol`; nothing here may reach back into the daemon.
//!
//! `task_board_item_requests` and `task_board_spawn_gate` moved into
//! `harness-task-board` with the rest of this slice; this glob brings them
//! back into `crate::task_board::wire::*` for every existing caller. The
//! other files here reach into `dispatch`/`automation`/`triage*`/
//! `policy_graph`/`session`, which stay in this crate for later slices, so
//! they stay here too.
pub use harness_task_board::wire::*;

mod policy_transfer;
mod task_board;
mod task_board_automation;
mod task_board_steps;
mod task_board_triage;
mod task_board_triage_escalation;
mod task_board_triage_rules;

pub use policy_transfer::*;
pub use task_board::*;
pub use task_board_automation::*;
pub use task_board_steps::*;
pub use task_board_triage::*;
pub use task_board_triage_escalation::*;
pub use task_board_triage_rules::*;
