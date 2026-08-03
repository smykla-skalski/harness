//! The review-policy graph's own interface onto [`AsyncDaemonDb`]/[`DaemonDb`]:
//! the canvas workspace, decision feed, and approval-grant store that
//! `service::reviews`-adjacent code and task-board's dispatch path persist
//! through. The actual query logic lives in `harness-policy-graph-store`
//! (see #1116); this module owns the trait boundary onto it, per #1115's
//! decision on this cluster -- a sibling module next to `service::reviews`,
//! matching how `daemon::policy_runtime_store` already bridges task-board's
//! own policy-runtime traits. When #1086 extracts `service::reviews`, this
//! trait moves with it for free.
//!
//! No inherent impl remains on `AsyncDaemonDb`/`DaemonDb` here: every caller
//! reaches these methods through [`PolicyGraphQueries`] or
//! [`PolicyGraphSyncQueries`] instead, so this file carries no orphan-rule
//! obstacle to `AsyncDaemonDb`/`DaemonDb` moving to their own crate.

use harness_policy_graph_store::{
    NewApprovalGrant, PolicyCanvasDraftSaveResult, count_pending_approval_grants,
    ensure_pending_approval_grant, list_pending_approval_grants, live_approval_grant,
    load_policy_workspace, load_policy_workspace_sync, prune_policy_decisions,
    recent_policy_decisions_for_canvas, record_policy_decision_row, replace_policy_workspace,
    resolve_approval_grant, revoke_approval_grant, save_policy_canvas_draft,
    update_policy_workspace,
};
// No production caller reaches these `_at` clock-injection variants or
// `approval_grant` -- see the doc note on `PolicyGraphQueries` below -- so
// their imports stay test-only too, matching the methods that use them.
#[cfg(test)]
use harness_policy_graph_store::{
    approval_grant, count_pending_approval_grants_at, list_pending_approval_grants_at,
    live_approval_grant_at, resolve_approval_grant_at, revoke_approval_grant_at,
};

use crate::daemon::db::{AsyncDaemonDb, CliError, DaemonDb};
use crate::task_board::policy_graph::{PolicyCanvasWorkspace, PolicyGraph, RecordedPolicyDecision};
use crate::task_board::{PolicyAction, PolicyApprovalGrant};

#[cfg(test)]
#[path = "reviews_store_tests.rs"]
mod tests;

pub(crate) trait PolicyGraphQueries: Send + Sync {
    async fn ensure_pending_approval_grant(
        &self,
        grant: &NewApprovalGrant,
    ) -> Result<PolicyApprovalGrant, CliError>;
    async fn live_approval_grant(
        &self,
        board_item_id: &str,
        action: PolicyAction,
        canvas_revision: u64,
    ) -> Result<Option<PolicyApprovalGrant>, CliError>;
    // The `_at` clock-injection variants below, plus `approval_grant`, have no
    // production caller: real callers only ever need "now", and production
    // only reads a specific grant back through the id `ensure_pending_*`,
    // `resolve_*`, and `revoke_*` already return. Deterministic-clock tests
    // are their only consumer, so they stay test-only rather than carrying
    // dead production surface.
    #[cfg(test)]
    async fn live_approval_grant_at(
        &self,
        board_item_id: &str,
        action: PolicyAction,
        canvas_revision: u64,
        now: &str,
    ) -> Result<Option<PolicyApprovalGrant>, CliError>;
    #[cfg(test)]
    async fn approval_grant(&self, id: &str) -> Result<Option<PolicyApprovalGrant>, CliError>;
    async fn list_pending_approval_grants(&self) -> Result<Vec<PolicyApprovalGrant>, CliError>;
    #[cfg(test)]
    async fn list_pending_approval_grants_at(
        &self,
        now: &str,
    ) -> Result<Vec<PolicyApprovalGrant>, CliError>;
    async fn count_pending_approval_grants(&self) -> Result<usize, CliError>;
    #[cfg(test)]
    async fn count_pending_approval_grants_at(&self, now: &str) -> Result<usize, CliError>;
    async fn resolve_approval_grant(
        &self,
        id: &str,
        approve: bool,
        actor: &str,
    ) -> Result<PolicyApprovalGrant, CliError>;
    #[cfg(test)]
    async fn resolve_approval_grant_at(
        &self,
        id: &str,
        approve: bool,
        actor: &str,
        now: &str,
    ) -> Result<PolicyApprovalGrant, CliError>;
    async fn revoke_approval_grant(
        &self,
        id: &str,
        actor: &str,
    ) -> Result<PolicyApprovalGrant, CliError>;
    #[cfg(test)]
    async fn revoke_approval_grant_at(
        &self,
        id: &str,
        actor: &str,
        now: &str,
    ) -> Result<PolicyApprovalGrant, CliError>;
    async fn record_policy_decision_row(
        &self,
        decision: &RecordedPolicyDecision,
    ) -> Result<(), CliError>;
    async fn recent_policy_decisions_for_canvas(
        &self,
        canvas_id: &str,
        limit: usize,
    ) -> Result<Vec<RecordedPolicyDecision>, CliError>;
    async fn prune_policy_decisions(&self, keep: usize) -> Result<u64, CliError>;
    async fn load_policy_workspace(&self) -> Result<Option<PolicyCanvasWorkspace>, CliError>;
    async fn replace_policy_workspace(
        &self,
        workspace: &PolicyCanvasWorkspace,
    ) -> Result<(), CliError>;
    async fn save_policy_canvas_draft(
        &self,
        canvas_id: &str,
        document: PolicyGraph,
        if_revision: u64,
    ) -> Result<PolicyCanvasDraftSaveResult, CliError>;

    /// Atomically read-modify-write the policy workspace.
    async fn update_policy_workspace<F, R>(
        &self,
        mutate: F,
    ) -> Result<(PolicyCanvasWorkspace, R), CliError>
    where
        F: FnOnce(&mut PolicyCanvasWorkspace) -> Result<R, CliError> + Send,
        R: Send;
}

impl PolicyGraphQueries for AsyncDaemonDb {
    async fn ensure_pending_approval_grant(
        &self,
        grant: &NewApprovalGrant,
    ) -> Result<PolicyApprovalGrant, CliError> {
        ensure_pending_approval_grant(self, grant).await
    }

    async fn live_approval_grant(
        &self,
        board_item_id: &str,
        action: PolicyAction,
        canvas_revision: u64,
    ) -> Result<Option<PolicyApprovalGrant>, CliError> {
        live_approval_grant(self, board_item_id, action, canvas_revision).await
    }

    #[cfg(test)]
    async fn live_approval_grant_at(
        &self,
        board_item_id: &str,
        action: PolicyAction,
        canvas_revision: u64,
        now: &str,
    ) -> Result<Option<PolicyApprovalGrant>, CliError> {
        live_approval_grant_at(self, board_item_id, action, canvas_revision, now).await
    }

    #[cfg(test)]
    async fn approval_grant(&self, id: &str) -> Result<Option<PolicyApprovalGrant>, CliError> {
        approval_grant(self, id).await
    }

    async fn list_pending_approval_grants(&self) -> Result<Vec<PolicyApprovalGrant>, CliError> {
        list_pending_approval_grants(self).await
    }

    #[cfg(test)]
    async fn list_pending_approval_grants_at(
        &self,
        now: &str,
    ) -> Result<Vec<PolicyApprovalGrant>, CliError> {
        list_pending_approval_grants_at(self, now).await
    }

    async fn count_pending_approval_grants(&self) -> Result<usize, CliError> {
        count_pending_approval_grants(self).await
    }

    #[cfg(test)]
    async fn count_pending_approval_grants_at(&self, now: &str) -> Result<usize, CliError> {
        count_pending_approval_grants_at(self, now).await
    }

    async fn resolve_approval_grant(
        &self,
        id: &str,
        approve: bool,
        actor: &str,
    ) -> Result<PolicyApprovalGrant, CliError> {
        resolve_approval_grant(self, id, approve, actor).await
    }

    #[cfg(test)]
    async fn resolve_approval_grant_at(
        &self,
        id: &str,
        approve: bool,
        actor: &str,
        now: &str,
    ) -> Result<PolicyApprovalGrant, CliError> {
        resolve_approval_grant_at(self, id, approve, actor, now).await
    }

    async fn revoke_approval_grant(
        &self,
        id: &str,
        actor: &str,
    ) -> Result<PolicyApprovalGrant, CliError> {
        revoke_approval_grant(self, id, actor).await
    }

    #[cfg(test)]
    async fn revoke_approval_grant_at(
        &self,
        id: &str,
        actor: &str,
        now: &str,
    ) -> Result<PolicyApprovalGrant, CliError> {
        revoke_approval_grant_at(self, id, actor, now).await
    }

    async fn record_policy_decision_row(
        &self,
        decision: &RecordedPolicyDecision,
    ) -> Result<(), CliError> {
        record_policy_decision_row(self, decision).await
    }

    async fn recent_policy_decisions_for_canvas(
        &self,
        canvas_id: &str,
        limit: usize,
    ) -> Result<Vec<RecordedPolicyDecision>, CliError> {
        recent_policy_decisions_for_canvas(self, canvas_id, limit).await
    }

    async fn prune_policy_decisions(&self, keep: usize) -> Result<u64, CliError> {
        prune_policy_decisions(self, keep).await
    }

    async fn load_policy_workspace(&self) -> Result<Option<PolicyCanvasWorkspace>, CliError> {
        load_policy_workspace(self).await
    }

    async fn replace_policy_workspace(
        &self,
        workspace: &PolicyCanvasWorkspace,
    ) -> Result<(), CliError> {
        replace_policy_workspace(self, workspace).await
    }

    async fn save_policy_canvas_draft(
        &self,
        canvas_id: &str,
        document: PolicyGraph,
        if_revision: u64,
    ) -> Result<PolicyCanvasDraftSaveResult, CliError> {
        save_policy_canvas_draft(self, canvas_id, document, if_revision).await
    }

    async fn update_policy_workspace<F, R>(
        &self,
        mutate: F,
    ) -> Result<(PolicyCanvasWorkspace, R), CliError>
    where
        F: FnOnce(&mut PolicyCanvasWorkspace) -> Result<R, CliError> + Send,
        R: Send,
    {
        update_policy_workspace(self, mutate).await
    }
}

pub(crate) trait PolicyGraphSyncQueries {
    fn load_policy_workspace(&self) -> Result<Option<PolicyCanvasWorkspace>, CliError>;
}

impl PolicyGraphSyncQueries for DaemonDb {
    fn load_policy_workspace(&self) -> Result<Option<PolicyCanvasWorkspace>, CliError> {
        load_policy_workspace_sync(self.connection())
    }
}

