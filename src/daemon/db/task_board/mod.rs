//! Canonical `SQLite` persistence for Task Board domain state.

mod aggregates;
mod dispatch_intents;
mod dispatch_preparations;
mod held_dispatch;
mod import_lifecycle;
mod imports;
mod items;
mod mapper;
mod policy_queues;
mod policy_runs;
mod rows;

pub(crate) use dispatch_intents::ClaimedTaskBoardDispatch;
pub(crate) use dispatch_preparations::{
    ClaimedTaskBoardDispatchPreparation, ReservedTaskBoardDispatch,
};
#[allow(unused_imports)]
pub(crate) use imports::{TaskBoardImportMarker, TaskBoardImportResult};
#[allow(unused_imports)]
pub(crate) use items::TaskBoardMutation;

pub(crate) const ITEMS_CHANGE_SCOPE: &str = "task_board:items";
pub(crate) const MACHINES_CHANGE_SCOPE: &str = "task_board:machines";
pub(crate) const ORCHESTRATOR_CHANGE_SCOPE: &str = "task_board:orchestrator";
pub(crate) const POLICY_RUNTIME_CHANGE_SCOPE: &str = "task_board:policy_runtime";
pub(crate) const RUNTIME_CONFIG_CHANGE_SCOPE: &str = "task_board:runtime_config";
