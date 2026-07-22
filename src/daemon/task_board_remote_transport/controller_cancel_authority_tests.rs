use std::sync::Arc;

use super::controller_authority_test_support::{
    BarrierServer, TOKEN_ENV, pinned_controller_with_times, spawn_barrier_server,
    spawn_probe_server, test_tls_material,
};
use super::controller_authority_tests::assert_concurrent_database_error;
use super::controller_prepared_test_support::{
    claim_request, claim_response, persist_claim, prepared_acceptance, renewal_request,
    renewal_response,
};
use super::controller_tests::{cancel_request, cancel_response, claimed_cancel_response};
use crate::daemon::db::TaskBoardRemoteMutationOutcome;
use crate::task_board::TaskBoardRemoteAssignmentState;

#[tokio::test]
async fn claim_authority_wins_before_cancel_and_cancel_performs_zero_io() {
    let state = prepared_acceptance("claim-authority-before-cancel").await;
    let claim = claim_request(&state);
    let claim_response = claim_response(&state);
    let cancel = cancel_request(&state.prepared.offer, "lease-admission");
    let tls = test_tls_material();
    let BarrierServer {
        endpoint,
        seen,
        release,
        requests,
    } = spawn_barrier_server(
        &tls,
        serde_json::to_string(&claim_response).expect("claim response JSON"),
    )
    .await;
    let (cancel_endpoint, cancel_requests) = spawn_probe_server(&tls).await;
    let claim_controller = Arc::new(pinned_controller_with_times(
        &endpoint,
        &tls,
        [
            state.times.before_expiry.clone(),
            state.times.before_expiry.clone(),
        ],
    ));
    let cancel_controller =
        pinned_controller_with_times(&cancel_endpoint, &tls, [state.times.before_expiry.clone()]);

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let controller = Arc::clone(&claim_controller);
        let db = (*state.prepared.db).clone();
        let request = claim.clone();
        let call = tokio::spawn(async move { controller.claim(&db, &request).await });
        seen.await
            .expect("claim crossed durable authority boundary");
        let error = cancel_controller
            .cancel(&state.prepared.db, &cancel)
            .await
            .expect_err("claim authority must fence cancellation");
        assert_concurrent_database_error(error);
        release.send(()).expect("release claim response");
        let outcome = call
            .await
            .expect("claim task")
            .expect("claim settles after winning authority");
        assert!(matches!(
            outcome.1,
            TaskBoardRemoteMutationOutcome::Updated(ref record)
                if record.state == TaskBoardRemoteAssignmentState::Claimed
        ));
    })
    .await;
    assert_eq!(requests.await.expect("claim barrier"), 1);
    assert_eq!(cancel_requests.await.expect("cancel probe"), 0);
}

#[tokio::test]
async fn cancel_authority_wins_before_claim_and_claim_performs_zero_io() {
    let state = prepared_acceptance("cancel-authority-before-claim").await;
    let claim = claim_request(&state);
    let cancel = cancel_request(&state.prepared.offer, "lease-admission");
    let cancel_response = cancel_response(&state.prepared.offer, &state.times.before_expiry);
    let tls = test_tls_material();
    let BarrierServer {
        endpoint,
        seen,
        release,
        requests,
    } = spawn_barrier_server(
        &tls,
        serde_json::to_string(&cancel_response).expect("cancel response JSON"),
    )
    .await;
    let (claim_endpoint, claim_requests) = spawn_probe_server(&tls).await;
    let cancel_controller = Arc::new(pinned_controller_with_times(
        &endpoint,
        &tls,
        [
            state.times.before_expiry.clone(),
            state.times.before_expiry.clone(),
        ],
    ));
    let claim_controller =
        pinned_controller_with_times(&claim_endpoint, &tls, [state.times.before_expiry.clone()]);

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let controller = Arc::clone(&cancel_controller);
        let db = (*state.prepared.db).clone();
        let request = cancel.clone();
        let call = tokio::spawn(async move { controller.cancel(&db, &request).await });
        seen.await
            .expect("cancel crossed durable authority boundary");
        let error = claim_controller
            .claim(&state.prepared.db, &claim)
            .await
            .expect_err("cancel authority must fence claim");
        assert_concurrent_database_error(error);
        release.send(()).expect("release cancel response");
        let outcome = call
            .await
            .expect("cancel task")
            .expect("cancel settles after winning authority");
        assert!(matches!(
            outcome.1,
            TaskBoardRemoteMutationOutcome::Updated(ref record)
                if record.state == TaskBoardRemoteAssignmentState::Cancelled
        ));
    })
    .await;
    assert_eq!(requests.await.expect("cancel barrier"), 1);
    assert_eq!(claim_requests.await.expect("claim probe"), 0);
}

#[tokio::test]
async fn renewal_authority_wins_before_cancel_and_cancel_performs_zero_io() {
    let state = prepared_acceptance("renew-authority-before-cancel").await;
    persist_claim(&state).await;
    let renewal = renewal_request(&state);
    let renewal_response = renewal_response(&state);
    let cancel = cancel_request(&state.prepared.offer, "lease-admission");
    let tls = test_tls_material();
    let BarrierServer {
        endpoint,
        seen,
        release,
        requests,
    } = spawn_barrier_server(
        &tls,
        serde_json::to_string(&renewal_response).expect("renewal response JSON"),
    )
    .await;
    let (cancel_endpoint, cancel_requests) = spawn_probe_server(&tls).await;
    let renewal_controller = Arc::new(pinned_controller_with_times(
        &endpoint,
        &tls,
        [
            state.times.before_expiry.clone(),
            state.times.before_expiry.clone(),
        ],
    ));
    let cancel_controller =
        pinned_controller_with_times(&cancel_endpoint, &tls, [state.times.before_expiry.clone()]);

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let controller = Arc::clone(&renewal_controller);
        let db = (*state.prepared.db).clone();
        let request = renewal.clone();
        let call = tokio::spawn(async move { controller.renew_lease(&db, &request).await });
        seen.await
            .expect("renewal crossed durable authority boundary");
        let error = cancel_controller
            .cancel(&state.prepared.db, &cancel)
            .await
            .expect_err("renewal authority must fence cancellation");
        assert_concurrent_database_error(error);
        release.send(()).expect("release renewal response");
        let outcome = call
            .await
            .expect("renewal task")
            .expect("renewal settles after winning authority");
        assert!(matches!(
            outcome.1,
            TaskBoardRemoteMutationOutcome::Updated(ref record)
                if record.lease_id.as_deref() == Some("lease-l2")
        ));
    })
    .await;
    assert_eq!(requests.await.expect("renewal barrier"), 1);
    assert_eq!(cancel_requests.await.expect("cancel probe"), 0);
}

#[tokio::test]
async fn cancel_authority_wins_before_renewal_and_renewal_performs_zero_io() {
    let state = prepared_acceptance("cancel-authority-before-renew").await;
    persist_claim(&state).await;
    let renewal = renewal_request(&state);
    let cancel = cancel_request(&state.prepared.offer, "lease-admission");
    let cancel_response = claimed_cancel_response(
        &state.prepared.offer,
        &state.times.before_expiry,
        &state.times.before_expiry,
    );
    let tls = test_tls_material();
    let BarrierServer {
        endpoint,
        seen,
        release,
        requests,
    } = spawn_barrier_server(
        &tls,
        serde_json::to_string(&cancel_response).expect("cancel response JSON"),
    )
    .await;
    let (renew_endpoint, renew_requests) = spawn_probe_server(&tls).await;
    let cancel_controller = Arc::new(pinned_controller_with_times(
        &endpoint,
        &tls,
        [
            state.times.before_expiry.clone(),
            state.times.before_expiry.clone(),
        ],
    ));
    let renewal_controller =
        pinned_controller_with_times(&renew_endpoint, &tls, [state.times.before_expiry.clone()]);

    temp_env::async_with_vars([(TOKEN_ENV, Some("authority-secret"))], async {
        let controller = Arc::clone(&cancel_controller);
        let db = (*state.prepared.db).clone();
        let request = cancel.clone();
        let call = tokio::spawn(async move { controller.cancel(&db, &request).await });
        seen.await
            .expect("cancel crossed durable authority boundary");
        let error = renewal_controller
            .renew_lease(&state.prepared.db, &renewal)
            .await
            .expect_err("cancel authority must fence renewal");
        assert_concurrent_database_error(error);
        release.send(()).expect("release cancel response");
        let outcome = call
            .await
            .expect("cancel task")
            .expect("cancel settles after winning authority");
        assert!(matches!(
            outcome.1,
            TaskBoardRemoteMutationOutcome::Updated(ref record)
                if record.state == TaskBoardRemoteAssignmentState::Cancelled
        ));
    })
    .await;
    assert_eq!(requests.await.expect("cancel barrier"), 1);
    assert_eq!(renew_requests.await.expect("renewal probe"), 0);
}
