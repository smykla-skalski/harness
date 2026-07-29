//! Small pieces this crate needs its own copy of because their originals
//! are `pub(crate)`/`pub(super)` inside `harness-daemon` and this crate
//! cannot depend on `harness-daemon` (see `store.rs`). Every value here must
//! stay byte-identical to its `harness-daemon` counterpart.

use std::borrow::Cow;

use harness_kernel::errors::{CliError, CliErrorKind};

/// Mirrors `crate::daemon::db::db_error` in `harness-daemon`.
pub(crate) fn db_error(detail: impl Into<Cow<'static, str>>) -> CliError {
    CliError::from(CliErrorKind::workflow_io(detail))
}

/// Mirrors `ITEMS_CHANGE_SCOPE` in `daemon/db/task_board/mod.rs`.
pub(crate) const ITEMS_CHANGE_SCOPE: &str = "task_board:items";

/// Mirrors `ORCHESTRATOR_CHANGE_SCOPE` in `daemon/db/task_board/mod.rs`.
pub(crate) const ORCHESTRATOR_CHANGE_SCOPE: &str = "task_board:orchestrator";
