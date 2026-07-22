//! Test-only access to the production remote executor tick and its scoped seam.

pub(crate) use super::background_tasks::{
    RuntimeSeamScope, install_deterministic_runtime_seam,
    reconcile_task_board_remote_executor_tick,
};
