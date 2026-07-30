//! The dispatch and admission-ledger cluster's own interface onto the
//! transaction every other `task_board` area already borrows to check and
//! reserve admission, revalidate a claim, or read dispatch-intent identity.
//!
//! The cluster's load-bearing helpers -- `has_active_dispatch_reservation_in_tx`,
//! `revalidate_dispatch_admission_in_tx`, and the rest below -- are plain
//! `async fn`s whose first parameter is a borrowed, foreign `sqlx::Transaction`,
//! not a method on a type the cluster owns. That is why every sibling area
//! (the item core, triage, workflow execution, provider sync) has always
//! reached them by importing the free function directly instead of going
//! through any boundary: there was no boundary to go through. A local trait
//! implemented for the foreign `Transaction` closes that gap the same way
//! `TaskBoardItemTxExt` closes it for the item core's own load/mutate
//! helpers -- Rust's orphan rule only requires one of the trait or the
//! implementing type to be local, and the trait is -- so a caller writes
//! `transaction.has_active_dispatch_reservation_in_tx(item_id).await?`
//! through one named, greppable surface instead of reaching into whichever
//! file happens to define the free function today.
//!
//! This is deliberately narrower than [`super::dispatch_admission_queries`]'s
//! `DispatchAdmissionQueries`, this cluster's other boundary. That trait is
//! the cluster's externally-reachable operations (enqueue, claim, prepare,
//! complete a dispatch); this one is the internal admission and reservation
//! checks those operations -- and every sibling area listed above -- already
//! share mid-transaction. Folding them into one trait would force a caller
//! that only needs a reservation check to depend on the cluster's entire
//! public surface instead.
//!
//! Pure functions with no transaction receiver (`ensure_dispatch_item_startable`)
//! and plain types (`TaskBoardAdmissionCheck`) are deliberately not here
//! either: there is no `&mut self` to hang a method off, so they stay plain
//! functions and types where they already live.
//!
//! Every method below is a thin, single-line forward into the free function
//! that actually owns the logic, kept in the file it has always lived in
//! (`admission_lifecycle.rs`, `dispatch_intents.rs`, `dispatch_intents_helpers.rs`),
//! so this file stays a pure interface plus wiring.

use sqlx::{Sqlite, Transaction};

use super::admission_lifecycle::TaskBoardAdmissionCheck;
use crate::daemon::db::CliError;
use crate::task_board::{DispatchAppliedTask, TaskBoardItem};

pub(in crate::daemon::db::task_board) trait TaskBoardDispatchAdmissionTxExt {
    async fn has_active_dispatch_reservation_in_tx(
        &mut self,
        item_id: &str,
    ) -> Result<bool, CliError>;

    async fn ensure_item_admission_can_terminate_in_tx(
        &mut self,
        item_id: &str,
    ) -> Result<(), CliError>;

    async fn release_item_admission_in_tx(&mut self, item_id: &str) -> Result<(), CliError>;

    async fn release_managed_worker_admission_in_tx(
        &mut self,
        managed_worker_id: &str,
    ) -> Result<bool, CliError>;

    async fn revalidate_dispatch_admission_in_tx(
        &mut self,
        intent_id: &str,
        item: &TaskBoardItem,
        item_revision: i64,
    ) -> Result<TaskBoardAdmissionCheck, CliError>;

    async fn release_dispatch_admission_in_tx(&mut self, intent_id: &str) -> Result<(), CliError>;

    async fn renew_dispatch_admission_in_tx(&mut self, intent_id: &str) -> Result<(), CliError>;

    async fn renew_frozen_dispatch_admission_in_tx(
        &mut self,
        intent_id: &str,
    ) -> Result<(), CliError>;

    async fn commit_dispatch_admission_in_tx(
        &mut self,
        intent_id: &str,
        managed_worker_id: &str,
    ) -> Result<(), CliError>;

    async fn validate_worker_start_fence_in_tx(
        &mut self,
        expected_read_only_fence: Option<(i64, u64)>,
        loaded_item_revision: i64,
    ) -> Result<(), CliError>;

    async fn dispatch_claimed_intent_identity_in_tx(
        &mut self,
        intent_id: &str,
        claim_token: &str,
    ) -> Result<(String, String, String, String), CliError>;

    async fn refuse_pending_admission_in_tx(
        &mut self,
        intent_id: &str,
        applied: &DispatchAppliedTask,
        consumed_approval_grant_id: Option<&str>,
        reason: &str,
    ) -> Result<(), CliError>;
}

impl TaskBoardDispatchAdmissionTxExt for Transaction<'_, Sqlite> {
    async fn has_active_dispatch_reservation_in_tx(
        &mut self,
        item_id: &str,
    ) -> Result<bool, CliError> {
        super::dispatch_intents::helpers::has_active_dispatch_reservation_in_tx(self, item_id).await
    }

    async fn ensure_item_admission_can_terminate_in_tx(
        &mut self,
        item_id: &str,
    ) -> Result<(), CliError> {
        super::admission_lifecycle::ensure_item_admission_can_terminate_in_tx(self, item_id).await
    }

    async fn release_item_admission_in_tx(&mut self, item_id: &str) -> Result<(), CliError> {
        super::admission_lifecycle::release_item_admission_in_tx(self, item_id).await
    }

    async fn release_managed_worker_admission_in_tx(
        &mut self,
        managed_worker_id: &str,
    ) -> Result<bool, CliError> {
        super::admission_lifecycle::release_managed_worker_admission_in_tx(self, managed_worker_id)
            .await
    }

    async fn revalidate_dispatch_admission_in_tx(
        &mut self,
        intent_id: &str,
        item: &TaskBoardItem,
        item_revision: i64,
    ) -> Result<TaskBoardAdmissionCheck, CliError> {
        super::admission_lifecycle::revalidate_dispatch_admission_in_tx(
            self,
            intent_id,
            item,
            item_revision,
        )
        .await
    }

    async fn release_dispatch_admission_in_tx(&mut self, intent_id: &str) -> Result<(), CliError> {
        super::admission_lifecycle::release_dispatch_admission_in_tx(self, intent_id).await
    }

    async fn renew_dispatch_admission_in_tx(&mut self, intent_id: &str) -> Result<(), CliError> {
        super::admission_lifecycle::renew_dispatch_admission_in_tx(self, intent_id).await
    }

    async fn renew_frozen_dispatch_admission_in_tx(
        &mut self,
        intent_id: &str,
    ) -> Result<(), CliError> {
        super::admission_lifecycle::renew_frozen_dispatch_admission_in_tx(self, intent_id).await
    }

    async fn commit_dispatch_admission_in_tx(
        &mut self,
        intent_id: &str,
        managed_worker_id: &str,
    ) -> Result<(), CliError> {
        super::admission_lifecycle::commit_dispatch_admission_in_tx(
            self,
            intent_id,
            managed_worker_id,
        )
        .await
    }

    async fn validate_worker_start_fence_in_tx(
        &mut self,
        expected_read_only_fence: Option<(i64, u64)>,
        loaded_item_revision: i64,
    ) -> Result<(), CliError> {
        super::admission_lifecycle::validate_worker_start_fence_in_tx(
            self,
            expected_read_only_fence,
            loaded_item_revision,
        )
        .await
    }

    async fn dispatch_claimed_intent_identity_in_tx(
        &mut self,
        intent_id: &str,
        claim_token: &str,
    ) -> Result<(String, String, String, String), CliError> {
        super::dispatch_intents::claimed_intent_identity(self, intent_id, claim_token).await
    }

    async fn refuse_pending_admission_in_tx(
        &mut self,
        intent_id: &str,
        applied: &DispatchAppliedTask,
        consumed_approval_grant_id: Option<&str>,
        reason: &str,
    ) -> Result<(), CliError> {
        super::dispatch_intents::helpers::refuse_pending_admission_in_tx(
            self,
            intent_id,
            applied,
            consumed_approval_grant_id,
            reason,
        )
        .await
    }
}
