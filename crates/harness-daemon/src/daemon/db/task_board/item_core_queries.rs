//! Item core CRUD and AI review report query surface for [`AsyncDaemonDb`],
//! consolidated behind one trait so its real bodies -- spread across
//! `items.rs`, `items_reads.rs`, `items::create`, `items::update`, and
//! `review_reports.rs` -- can each stay in the file they already live in.
//! Rust only allows one `impl Trait for Type` block per type, so this file
//! is the single place `ItemCoreQueries` is implemented; every method body
//! is a one-line forward into the plain function that owns the real logic.
//!
//! Daemon callers import this trait through `task_board::prelude`. Downstream
//! migration fixtures use the narrower feature-gated schema query facade.

use super::items::{TaskBoardItemSnapshot, TaskBoardMutation};
use super::lane_order::TaskBoardItemsSnapshot;
use super::{items, items_reads, review_reports};
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::{TaskBoardAiReviewReportRecord, TaskBoardItem, TaskBoardStatus};

pub(crate) trait ItemCoreQueries: Send + Sync {
    /// Load one Task Board item, including tombstones.
    ///
    /// # Errors
    /// Returns [`CliError`] when the item does not exist or the load fails.
    async fn task_board_item(&self, item_id: &str) -> Result<TaskBoardItem, CliError>;

    /// Load one Task Board item with the row revision used by automation CAS.
    ///
    /// # Errors
    /// Returns [`CliError`] when the item does not exist or the load fails.
    async fn task_board_item_snapshot(
        &self,
        item_id: &str,
    ) -> Result<TaskBoardItemSnapshot, CliError>;

    /// Like [`ItemCoreQueries::task_board_item`], but returns `Ok(None)` for a
    /// genuinely missing item instead of an error, so a caller that needs to
    /// distinguish "not found" from a real database failure does not have to
    /// fail closed on every error alike.
    async fn find_task_board_item(&self, item_id: &str) -> Result<Option<TaskBoardItem>, CliError>;

    /// List active Task Board items in the legacy stable ordering.
    async fn list_task_board_items(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError>;

    /// Tombstone one Task Board item.
    async fn delete_task_board_item(&self, item_id: &str) -> Result<TaskBoardMutation, CliError>;

    /// Insert one new Task Board item. Never evaluates `BuiltInV1`: every
    /// internal lane/dispatch/workflow/migration/test-fixture constructor
    /// must keep using this method so an unrelated internal create can never
    /// become accidental triage ingress. The public create API and provider
    /// import use the `_with_triage` methods below instead.
    ///
    /// # Errors
    /// Returns [`CliError`] when the item is invalid or the insert fails.
    async fn create_task_board_item(
        &self,
        item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError>;

    /// Like [`ItemCoreQueries::create_task_board_item`], but also evaluates
    /// `BuiltInV1` in the same transaction, for the public create API.
    async fn create_task_board_item_with_triage(
        &self,
        item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError>;

    /// Like [`ItemCoreQueries::create_task_board_item_with_triage`], but for a
    /// create whose request named the starting lane. The decision is still
    /// recorded, so a later clear or re-evaluation has one to reconcile
    /// against, but the placement effect never runs -- exactly how a human
    /// status move through the update API is treated.
    async fn create_task_board_item_at_requested_status(
        &self,
        item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError>;

    /// Like [`ItemCoreQueries::create_task_board_item`], but also evaluates
    /// `BuiltInV1` in the same transaction, for provider import.
    async fn create_task_board_item_with_provider_triage(
        &self,
        item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError>;

    /// Read a single consistent item-list sequence and per-item revisions.
    async fn task_board_items_snapshot(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<TaskBoardItemsSnapshot, CliError>;

    /// Test a picked item against its list sequence and row revision.
    async fn task_board_item_snapshot_is_current(
        &self,
        item_id: &str,
        item_revision: i64,
        items_change_seq: i64,
    ) -> Result<bool, CliError>;

    /// List Task Board items including tombstones.
    async fn list_task_board_items_including_deleted(&self)
    -> Result<Vec<TaskBoardItem>, CliError>;

    /// Like [`ItemCoreQueries::list_task_board_items_including_deleted`], but
    /// keeps each item's row revision, for a batch caller that needs to CAS
    /// an exact matched revision without a second point read.
    async fn list_task_board_item_snapshots_including_deleted(
        &self,
    ) -> Result<Vec<TaskBoardItemSnapshot>, CliError>;

    /// Atomically load and conditionally mutate one Task Board item. Never
    /// evaluates `BuiltInV1`: every internal workflow/lifecycle mutation
    /// (dispatch, planning, estimates, reviews, GitHub projection, ...) must
    /// keep using this method so unrelated writes can never become
    /// accidental triage ingress. The public update API and provider
    /// create/reconcile/restore use the `_with_triage` methods below
    /// instead.
    async fn update_task_board_item<F>(
        &self,
        item_id: &str,
        mutate: F,
    ) -> Result<Option<TaskBoardMutation>, CliError>
    where
        F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>;

    /// Evaluation follows session state, but it must not advance an item while
    /// dispatch admission still owns the item's exact revision. The worker
    /// claim clears that reservation before later evaluations may resume.
    async fn update_task_board_item_for_evaluation<F>(
        &self,
        item_id: &str,
        mutate: F,
    ) -> Result<Option<TaskBoardMutation>, CliError>
    where
        F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>;

    /// Like [`ItemCoreQueries::update_task_board_item`], but also evaluates
    /// `BuiltInV1` in the same transaction, for the public update API: a
    /// same-call status or placement change is a direct human effect and
    /// suppresses `BuiltInV1` placement (decision history still refreshes).
    async fn update_task_board_item_with_triage<F>(
        &self,
        item_id: &str,
        mutate: F,
    ) -> Result<Option<TaskBoardMutation>, CliError>
    where
        F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>;

    /// Like [`ItemCoreQueries::update_task_board_item_with_triage`], but for
    /// provider create/reconcile/restore: a same-call status or placement
    /// change reflects provider evidence, not a human override, so it never
    /// suppresses `BuiltInV1` placement on its own. Only a pre-existing
    /// manual lane anchor still suppresses.
    async fn update_task_board_item_with_provider_triage<F>(
        &self,
        item_id: &str,
        mutate: F,
    ) -> Result<Option<TaskBoardMutation>, CliError>
    where
        F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>;

    async fn append_task_board_ai_review_report(
        &self,
        report: &TaskBoardAiReviewReportRecord,
    ) -> Result<bool, CliError>;

    async fn task_board_ai_review_reports(
        &self,
        item_id: &str,
    ) -> Result<Vec<TaskBoardAiReviewReportRecord>, CliError>;

    async fn task_board_latest_ai_review_report(
        &self,
        item_id: &str,
    ) -> Result<Option<TaskBoardAiReviewReportRecord>, CliError>;
}

/// The trait's one and only impl for [`AsyncDaemonDb`]. Every method is a
/// thin, single-line forward into the plain function that actually owns the
/// area's query logic, kept in the file the query has always lived in.
impl ItemCoreQueries for AsyncDaemonDb {
    async fn task_board_item(&self, item_id: &str) -> Result<TaskBoardItem, CliError> {
        items::task_board_item(self, item_id).await
    }

    async fn task_board_item_snapshot(
        &self,
        item_id: &str,
    ) -> Result<TaskBoardItemSnapshot, CliError> {
        items::task_board_item_snapshot(self, item_id).await
    }

    async fn find_task_board_item(&self, item_id: &str) -> Result<Option<TaskBoardItem>, CliError> {
        items::find_task_board_item(self, item_id).await
    }

    async fn list_task_board_items(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        items::list_task_board_items(self, status).await
    }

    async fn delete_task_board_item(&self, item_id: &str) -> Result<TaskBoardMutation, CliError> {
        items::delete_task_board_item(self, item_id).await
    }

    async fn create_task_board_item(
        &self,
        item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError> {
        Box::pin(items::create::create_task_board_item(self, item)).await
    }

    async fn create_task_board_item_with_triage(
        &self,
        item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError> {
        Box::pin(items::create::create_task_board_item_with_triage(
            self, item,
        ))
        .await
    }

    async fn create_task_board_item_at_requested_status(
        &self,
        item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError> {
        Box::pin(items::create::create_task_board_item_at_requested_status(
            self, item,
        ))
        .await
    }

    async fn create_task_board_item_with_provider_triage(
        &self,
        item: TaskBoardItem,
    ) -> Result<TaskBoardMutation, CliError> {
        Box::pin(items::create::create_task_board_item_with_provider_triage(
            self, item,
        ))
        .await
    }

    async fn task_board_items_snapshot(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<TaskBoardItemsSnapshot, CliError> {
        items_reads::task_board_items_snapshot(self, status).await
    }

    async fn task_board_item_snapshot_is_current(
        &self,
        item_id: &str,
        item_revision: i64,
        items_change_seq: i64,
    ) -> Result<bool, CliError> {
        items_reads::task_board_item_snapshot_is_current(
            self,
            item_id,
            item_revision,
            items_change_seq,
        )
        .await
    }

    async fn list_task_board_items_including_deleted(
        &self,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        items_reads::list_task_board_items_including_deleted(self).await
    }

    async fn list_task_board_item_snapshots_including_deleted(
        &self,
    ) -> Result<Vec<TaskBoardItemSnapshot>, CliError> {
        items_reads::list_task_board_item_snapshots_including_deleted(self).await
    }

    async fn update_task_board_item<F>(
        &self,
        item_id: &str,
        mutate: F,
    ) -> Result<Option<TaskBoardMutation>, CliError>
    where
        F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>,
    {
        items::update::update_task_board_item(self, item_id, mutate).await
    }

    async fn update_task_board_item_for_evaluation<F>(
        &self,
        item_id: &str,
        mutate: F,
    ) -> Result<Option<TaskBoardMutation>, CliError>
    where
        F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>,
    {
        items::update::update_task_board_item_for_evaluation(self, item_id, mutate).await
    }

    async fn update_task_board_item_with_triage<F>(
        &self,
        item_id: &str,
        mutate: F,
    ) -> Result<Option<TaskBoardMutation>, CliError>
    where
        F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>,
    {
        items::update::update_task_board_item_with_triage(self, item_id, mutate).await
    }

    async fn update_task_board_item_with_provider_triage<F>(
        &self,
        item_id: &str,
        mutate: F,
    ) -> Result<Option<TaskBoardMutation>, CliError>
    where
        F: FnOnce(&mut TaskBoardItem) -> Result<bool, CliError>,
    {
        items::update::update_task_board_item_with_provider_triage(self, item_id, mutate).await
    }

    async fn append_task_board_ai_review_report(
        &self,
        report: &TaskBoardAiReviewReportRecord,
    ) -> Result<bool, CliError> {
        review_reports::append_task_board_ai_review_report(self, report).await
    }

    async fn task_board_ai_review_reports(
        &self,
        item_id: &str,
    ) -> Result<Vec<TaskBoardAiReviewReportRecord>, CliError> {
        review_reports::task_board_ai_review_reports(self, item_id).await
    }

    async fn task_board_latest_ai_review_report(
        &self,
        item_id: &str,
    ) -> Result<Option<TaskBoardAiReviewReportRecord>, CliError> {
        review_reports::task_board_latest_ai_review_report(self, item_id).await
    }
}
