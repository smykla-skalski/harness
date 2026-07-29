use async_trait::async_trait;
use harness_kernel::errors::CliError;
use harness_task_board::github::{PullRequestActionStore, RecordedAction};

use crate::daemon::db::AsyncDaemonDb;

#[async_trait]
impl PullRequestActionStore for AsyncDaemonDb {
    async fn load(&self, id: &str) -> Result<Option<RecordedAction>, CliError> {
        self.load_pull_request_action(id).await
    }

    async fn upsert(&self, record: RecordedAction) -> Result<(), CliError> {
        self.upsert_pull_request_action(record).await
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use harness_kernel::errors::CliErrorKind;
    use harness_task_board::github::{
        ActionGateRequirement, ActionState, InMemoryPullRequestEvidenceSource, MergeLedgerOutcome,
        Mergeability, PullRequestAction, PullRequestActionFailureClass, PullRequestActionKind,
        PullRequestActionStore, PullRequestEvidence, PullRequestIdentity, PullRequestLifecycle,
        PullRequestMergeGates, RecordedAction, ReviewDecision, ReviewGate, merge_with_ledger,
    };
    use tempfile::{TempDir, tempdir};

    use crate::daemon::db::AsyncDaemonDb;

    // The caller keeps the returned TempDir alive; dropping it removes the
    // database files out from under the open pool.
    async fn open_db() -> (AsyncDaemonDb, TempDir) {
        let dir = tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
            .await
            .expect("open database");
        (db, dir)
    }

    fn action(id: &str, url: Option<String>) -> PullRequestAction {
        PullRequestAction {
            id: id.to_owned(),
            kind: PullRequestActionKind::Merge,
            identity: PullRequestIdentity::from_slug("owner/repo", 42).with_url(url),
            head_revision: "head-sha".to_owned(),
        }
    }

    #[tokio::test]
    async fn fresh_load_returns_none() {
        let (db, _dir) = open_db().await;
        assert!(db.load("missing").await.expect("load").is_none());
    }

    #[tokio::test]
    async fn upsert_then_load_round_trips_pending() {
        let (db, _dir) = open_db().await;
        let record = RecordedAction {
            action: action("pending", Some("https://example/pr/42".to_owned())),
            state: ActionState::Pending,
            detail: None,
        };
        db.upsert(record.clone()).await.expect("upsert");
        assert_eq!(db.load("pending").await.expect("load"), Some(record));
    }

    #[tokio::test]
    async fn overwriting_the_same_id_updates_state() {
        let (db, _dir) = open_db().await;
        let pending = RecordedAction {
            action: action("merge", None),
            state: ActionState::Pending,
            detail: None,
        };
        db.upsert(pending.clone()).await.expect("upsert pending");
        let succeeded = RecordedAction {
            state: ActionState::Succeeded,
            ..pending
        };
        db.upsert(succeeded.clone())
            .await
            .expect("upsert succeeded");
        assert_eq!(db.load("merge").await.expect("load"), Some(succeeded));
    }

    #[tokio::test]
    async fn failed_transient_round_trips_with_detail() {
        let (db, _dir) = open_db().await;
        let record = RecordedAction {
            action: action("transient", None),
            state: ActionState::Failed(PullRequestActionFailureClass::Transient),
            detail: Some("rate limited".to_owned()),
        };
        db.upsert(record.clone()).await.expect("upsert");
        assert_eq!(db.load("transient").await.expect("load"), Some(record));
    }

    #[tokio::test]
    async fn failed_permanent_round_trips_with_detail() {
        let (db, _dir) = open_db().await;
        let record = RecordedAction {
            action: action("permanent", None),
            state: ActionState::Failed(PullRequestActionFailureClass::Permanent),
            detail: Some("rejected".to_owned()),
        };
        db.upsert(record.clone()).await.expect("upsert");
        assert_eq!(db.load("permanent").await.expect("load"), Some(record));
    }

    #[tokio::test]
    async fn uncertain_round_trips_with_detail() {
        let (db, _dir) = open_db().await;
        let record = RecordedAction {
            action: action("uncertain", None),
            state: ActionState::Uncertain,
            detail: Some("timeout after send".to_owned()),
        };
        db.upsert(record.clone()).await.expect("upsert");
        assert_eq!(db.load("uncertain").await.expect("load"), Some(record));
    }

    #[tokio::test]
    async fn url_absent_round_trips() {
        let (db, _dir) = open_db().await;
        let record = RecordedAction {
            action: action("no-url", None),
            state: ActionState::Pending,
            detail: None,
        };
        db.upsert(record.clone()).await.expect("upsert");
        let loaded = db.load("no-url").await.expect("load").expect("record");
        assert_eq!(loaded.action.identity.url, None);
        assert_eq!(loaded, record);
    }

    // The durable dedup guarantee across a process restart: an errored merge is
    // recorded uncertain, and a fresh process reconnecting the same database
    // reconciles it against evidence rather than re-issuing the merge.
    #[tokio::test]
    async fn a_durable_merge_is_never_reissued_across_a_restart() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("harness.db");
        let calls = AtomicUsize::new(0);

        // First process: the gate clears on a green pull request, the merge
        // request leaves, but its response is lost.
        {
            let db = AsyncDaemonDb::connect(&path).await.expect("open database");
            let before = InMemoryPullRequestEvidenceSource::new().with_evidence(open_evidence());
            let error = merge_with_ledger(
                &db,
                &before,
                action("merge", None),
                ActionGateRequirement::for_merge(),
                || async {
                    calls.fetch_add(1, Ordering::SeqCst);
                    Err(CliErrorKind::workflow_io("connection lost after send").into())
                },
            )
            .await
            .expect_err("a lost response surfaces the error");
            assert!(error.to_string().contains("connection lost"));
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        // Restart: a fresh process reconnects the same database and observes the
        // pull request already merged - the lost request had in fact applied.
        let db = AsyncDaemonDb::connect(&path)
            .await
            .expect("reopen database");
        let after = InMemoryPullRequestEvidenceSource::new().with_evidence(merged_evidence());
        let outcome = merge_with_ledger(
            &db,
            &after,
            action("merge", None),
            ActionGateRequirement::for_merge(),
            || async {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok(())
            },
        )
        .await
        .expect("the uncertain merge reconciles as applied");
        assert_eq!(outcome, MergeLedgerOutcome::AlreadyApplied);
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "a merge already applied must never be re-issued after a restart"
        );
    }

    fn merged_evidence() -> PullRequestEvidence {
        evidence(PullRequestLifecycle::Merged)
    }

    fn open_evidence() -> PullRequestEvidence {
        evidence(PullRequestLifecycle::Open)
    }

    fn evidence(lifecycle: PullRequestLifecycle) -> PullRequestEvidence {
        PullRequestEvidence {
            identity: PullRequestIdentity::from_slug("owner/repo", 42),
            head_revision: "head-sha".to_owned(),
            author: None,
            lifecycle,
            is_draft: false,
            gates: PullRequestMergeGates {
                mergeability: Mergeability::Mergeable,
                viewer_can_update: true,
                viewer_can_merge_as_admin: false,
                checks: Vec::new(),
                required_check_names: Vec::new(),
                review: ReviewGate {
                    decision: ReviewDecision::Approved,
                    current_approvals: 1,
                    required_approvals: 1,
                },
            },
            observed_at: "2026-07-29T00:00:00Z".to_owned(),
        }
    }
}
