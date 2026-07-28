//! Wire contracts for the task-board domain that this slice already owns.
//!
//! Most task-board wire types describe items alongside the domains that
//! still live in the root crate (`dispatch`, `automation`, `triage*`,
//! `policy_graph`, `session`), so they stay in `src/task_board/wire` for now
//! and reach these two files through the root crate's own facade. Only the
//! spawn-gate and item-request/query contracts are self-contained enough to
//! move with this slice.

mod task_board_item_requests;
mod task_board_spawn_gate;

pub use task_board_item_requests::*;
pub use task_board_spawn_gate::*;
