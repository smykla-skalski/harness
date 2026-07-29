//! Wire contracts for the task-board domain.
//!
//! These describe task-board requests and responses, so they carry the
//! domain's own types and belong beside it. The daemon re-exports them from
//! `crate::daemon::protocol`; nothing here may reach back into the daemon.
//!
//! Every file that used to live here (`task_board_item_requests`,
//! `task_board_spawn_gate`, and now the rest: `policy_transfer`,
//! `task_board`, `task_board_automation`, `task_board_steps`,
//! `task_board_triage`, `task_board_triage_escalation`,
//! `task_board_triage_rules`) has moved into `harness_task_board::wire`.
//! This glob brings all of it back into `crate::task_board::wire::*` for
//! every existing caller, matching `external.rs`/`github.rs`'s shape.
pub use harness_task_board::wire::*;
