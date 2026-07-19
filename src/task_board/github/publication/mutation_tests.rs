use std::sync::mpsc;
use std::time::Duration;

use tokio::sync::oneshot;

use super::git_ssh_publish::run_native_publication_worker;
use crate::github_api::{GitHubProtectedClient, stable_data_revision_guard};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancelled_waiter_leaves_native_mutation_owned_by_worker() {
    let _test_guard = crate::github_api::acquire_global_budget_test_lock().await;
    let mut changes = GitHubProtectedClient::data_changes();
    let initial_revision = GitHubProtectedClient::data_revision();
    let (started_tx, started_rx) = oneshot::channel();
    let (release_tx, release_rx) = mpsc::channel();

    let publication = tokio::spawn(run_native_publication_worker(move || {
        let _ = started_tx.send(());
        release_rx.recv().expect("release native worker");
        Ok(())
    }));
    started_rx.await.expect("native worker started");
    publication.abort();
    let cancelled = publication.await.expect_err("publication waiter cancelled");
    assert!(cancelled.is_cancelled());

    assert!(
        tokio::time::timeout(
            Duration::from_millis(25),
            stable_data_revision_guard(initial_revision),
        )
        .await
        .is_err(),
        "the native worker must retain the mutation barrier after caller cancellation"
    );
    release_tx.send(()).expect("release native worker");

    let change = tokio::time::timeout(Duration::from_secs(1), changes.recv())
        .await
        .expect("data change timeout")
        .expect("data change");
    assert_eq!(change.revision, initial_revision + 1);
    assert_eq!(change.operation, "task_board.github.publish_branch");
    assert!(
        changes.try_recv().is_err(),
        "mutation published more than once"
    );
}

#[test]
fn parent_mismatch_reports_expected_and_observed_revisions() {
    let error = super::validate_publication_parent(Some("expected-parent"), "observed-parent")
        .expect_err("parent mismatch must fail");
    let message = error.to_string();

    assert!(message.contains("expected 'expected-parent'"), "{message}");
    assert!(message.contains("observed 'observed-parent'"), "{message}");
}
