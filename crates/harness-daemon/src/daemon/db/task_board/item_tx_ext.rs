//! The item core's own interface onto the transaction every other
//! `task_board` area already borrows to read and write items.
//!
//! The core's load-bearing helpers -- `load_item_in_tx`, `replace_item_in_tx`,
//! and the rest below -- are plain `async fn`s whose first parameter is a
//! borrowed, foreign `sqlx::Transaction`, not a method on a type the core
//! owns. That is why every sibling area has always reached them by importing
//! the free function directly instead of going through any boundary: there
//! was no boundary to go through. A local trait implemented for the foreign
//! `Transaction` closes that gap the same way #1074's `ProviderQueries` closes
//! it for `AsyncDaemonDb` -- Rust's orphan rule only requires one of the trait
//! or the implementing type to be local, and the trait is -- so a caller
//! writes `transaction.load_item_in_tx(id).await?` through one named,
//! greppable surface instead of reaching into whichever file happens to
//! define the free function today.
//!
//! `bump_change_in_tx` is deliberately not here: its ~50 non-item callers
//! (machines, orchestrator settings, policy runtime, remote hosts, ...) have
//! nothing to do with `TaskBoardItem`, so it stays a plain free function.
//! `item_from_rows`, `ItemRow`, `ExternalRefRow`, and `validate_item` are
//! deliberately not here either: none of them take a transaction as their
//! first argument, so there is no `&mut self` to hang a method off; they stay
//! plain functions and types in `mapper.rs`, `rows.rs`, and `items.rs`.
//!
//! Every method below is a thin, single-line forward into the free function
//! that actually owns the logic, kept in the file it has always lived in
//! (`items.rs`, `items_write.rs`, `items_lifecycle.rs`, `items_parent.rs`),
//! so this file stays a pure interface plus wiring.

use async_trait::async_trait;
use sqlx::{Sqlite, Transaction};

use super::items::ParentAssignmentValidation;
use crate::daemon::db::CliError;
use crate::task_board::{TaskBoardItem, TaskBoardTriageOverride};

#[async_trait]
pub(in crate::daemon::db::task_board) trait TaskBoardItemTxExt {
    async fn load_item_in_tx(
        &mut self,
        item_id: &str,
    ) -> Result<Option<(TaskBoardItem, i64)>, CliError>;

    async fn load_item_with_triage_override_in_tx(
        &mut self,
        item_id: &str,
    ) -> Result<Option<(TaskBoardItem, i64, Option<TaskBoardTriageOverride>)>, CliError>;

    async fn insert_item_in_tx(
        &mut self,
        item: &TaskBoardItem,
        revision: i64,
    ) -> Result<(), CliError>;

    async fn replace_item_in_tx(
        &mut self,
        item: &TaskBoardItem,
        revision: i64,
    ) -> Result<(), CliError>;

    async fn apply_task_board_item_status_transition_in_tx(
        &mut self,
        item: &TaskBoardItem,
    ) -> Result<(), CliError>;

    async fn ensure_workflow_item_mutation_allowed_in_tx(
        &mut self,
        item_id: &str,
    ) -> Result<(), CliError>;

    async fn next_child_order_in_tx(&mut self, parent_id: &str) -> Result<u32, CliError>;

    async fn check_parent_assignment_in_tx(
        &mut self,
        item_id: &str,
        parent_id: &str,
    ) -> Result<ParentAssignmentValidation, CliError>;

    async fn clear_children_parent_in_tx(
        &mut self,
        parent_id: &str,
    ) -> Result<Vec<(String, i64)>, CliError>;

    async fn items_change_sequence_in_tx(&mut self) -> Result<i64, CliError>;
}

#[async_trait]
impl TaskBoardItemTxExt for Transaction<'_, Sqlite> {
    async fn load_item_in_tx(
        &mut self,
        item_id: &str,
    ) -> Result<Option<(TaskBoardItem, i64)>, CliError> {
        super::items::load_item_in_tx(self, item_id).await
    }

    async fn load_item_with_triage_override_in_tx(
        &mut self,
        item_id: &str,
    ) -> Result<Option<(TaskBoardItem, i64, Option<TaskBoardTriageOverride>)>, CliError> {
        super::items::load_item_with_triage_override_in_tx(self, item_id).await
    }

    async fn insert_item_in_tx(
        &mut self,
        item: &TaskBoardItem,
        revision: i64,
    ) -> Result<(), CliError> {
        super::items::insert_item_in_tx(self, item, revision).await
    }

    async fn replace_item_in_tx(
        &mut self,
        item: &TaskBoardItem,
        revision: i64,
    ) -> Result<(), CliError> {
        super::items::replace_item_in_tx(self, item, revision).await
    }

    async fn apply_task_board_item_status_transition_in_tx(
        &mut self,
        item: &TaskBoardItem,
    ) -> Result<(), CliError> {
        super::items::apply_task_board_item_status_transition_in_tx(self, item).await
    }

    async fn ensure_workflow_item_mutation_allowed_in_tx(
        &mut self,
        item_id: &str,
    ) -> Result<(), CliError> {
        super::items::ensure_workflow_item_mutation_allowed_in_tx(self, item_id).await
    }

    async fn next_child_order_in_tx(&mut self, parent_id: &str) -> Result<u32, CliError> {
        super::items::next_child_order_in_tx(self, parent_id).await
    }

    async fn check_parent_assignment_in_tx(
        &mut self,
        item_id: &str,
        parent_id: &str,
    ) -> Result<ParentAssignmentValidation, CliError> {
        super::items::check_parent_assignment_in_tx(self, item_id, parent_id).await
    }

    async fn clear_children_parent_in_tx(
        &mut self,
        parent_id: &str,
    ) -> Result<Vec<(String, i64)>, CliError> {
        super::items::clear_children_parent_in_tx(self, parent_id).await
    }

    async fn items_change_sequence_in_tx(&mut self) -> Result<i64, CliError> {
        super::items::items_change_sequence_in_tx(self).await
    }
}
