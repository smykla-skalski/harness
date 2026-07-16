use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use super::*;
use crate::github_api::begin_external_mutation;

#[tokio::test]
async fn post_error_with_duplicate_matches_returns_concurrent_evidence() {
    let _guard = acquire_global_budget_test_lock().await;
    let marked = render_body("body", KEY).expect("marker");
    let responses = vec![
        MockResponse::status(500, r#"{"message":"post failed"}"#),
        MockResponse::json(format!("[{}]", issue_json(26, &marked, false))),
        MockResponse::json(format!("[{}]", issue_json(27, &marked, false))),
        MockResponse::json("[]"),
    ];
    let (endpoint, captured, handle) = spawn_sequence_mock(responses);
    let client = sync_client(&endpoint, Some("acme/widgets"));

    let error = recovery(&client)
        .create_started(&request("body"), &TestLease::default())
        .await
        .expect_err("duplicate recovered issues");

    handle.join().expect("mock server");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    let captured = captured.lock().expect("captured");
    assert_eq!(captured.len(), 4);
    assert_eq!(
        captured
            .iter()
            .filter(|request| request.method == "POST")
            .count(),
        1
    );
}

#[tokio::test]
async fn data_revision_change_between_pages_restarts_the_entire_scan() {
    let _guard = acquire_global_budget_test_lock().await;
    let responses = vec![
        MockResponse::json(format!("[{}]", issue_json(28, "ordinary", false))),
        MockResponse::json("[]"),
        MockResponse::json(format!("[{}]", issue_json(28, "ordinary", false))),
        MockResponse::json("[]"),
    ];
    let (endpoint, captured, handle) = spawn_sequence_mock(responses);
    let client = sync_client(&endpoint, Some("acme/widgets"));
    let lease = RevisionChangingLease::default();

    let error = recovery(&client)
        .recover_existing(&request("body"), &lease)
        .await
        .expect_err("absent recovery remains blocked");

    handle.join().expect("mock server");
    assert_eq!(error.code(), "WORKFLOW_IO");
    assert_eq!(lease.renewals.load(Ordering::SeqCst), 4);
    let captured = captured.lock().expect("captured");
    assert_eq!(
        captured
            .iter()
            .map(|request| request.path.clone())
            .collect::<Vec<_>>(),
        vec![
            recovery_path(1),
            recovery_path(2),
            recovery_path(1),
            recovery_path(2),
        ]
    );
}

#[derive(Default)]
struct RevisionChangingLease {
    renewals: AtomicUsize,
    changed: AtomicBool,
}

#[async_trait]
impl ExternalCreateLease for RevisionChangingLease {
    async fn renew(&self) -> Result<(), CliError> {
        let call = self.renewals.fetch_add(1, Ordering::SeqCst) + 1;
        if call == 2 && !self.changed.swap(true, Ordering::SeqCst) {
            let mut mutation = begin_external_mutation("test.github.create_recovery_restart").await;
            mutation.mark_remote_success();
            drop(mutation);
        }
        Ok(())
    }
}
