use super::controller::RemoteExecutionControllerError;
use super::controller_authority_test_support::{
    TOKEN_ENV, central_offer, claim_request, persist_acceptance, pinned_controller,
    spawn_probe_server, test_tls_material, try_stop,
};

#[tokio::test]
async fn stop_after_central_offer_prevents_offer_network_io() {
    let state = central_offer().await;
    try_stop(&state, "stopped before offer I/O")
        .await
        .expect("stop wins before offer authority claim");
    let tls = test_tls_material();
    let (endpoint, requests) = spawn_probe_server(&tls).await;
    let controller = pinned_controller(&endpoint, &tls);
    let error = temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        controller
            .offer(&state.fixture.db, &state.fixture.request)
            .await
            .expect_err("stopped execution must fence offer before network I/O")
    })
    .await;

    assert_concurrent_database_error(error);
    assert_eq!(requests.await.expect("probe server"), 0);
}

#[tokio::test]
async fn stop_after_acceptance_prevents_claim_network_io() {
    let state = central_offer().await;
    persist_acceptance(&state).await;
    try_stop(&state, "stopped before claim I/O")
        .await
        .expect("stop wins before claim authority claim");
    let claim = claim_request(&state);
    let tls = test_tls_material();
    let (endpoint, requests) = spawn_probe_server(&tls).await;
    let controller = pinned_controller(&endpoint, &tls);
    let error = temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        controller
            .claim(&state.fixture.db, &claim)
            .await
            .expect_err("stopped execution must fence claim before network I/O")
    })
    .await;

    assert_concurrent_database_error(error);
    assert_eq!(requests.await.expect("probe server"), 0);
}

pub(super) fn assert_concurrent_database_error(error: RemoteExecutionControllerError) {
    match error {
        RemoteExecutionControllerError::Database(error) => {
            assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
        }
        other => panic!("expected database authority rejection before I/O, got {other:?}"),
    }
}
