use super::*;

#[test]
fn shutdown_after_session_creation_never_claims_or_starts() {
    run_deep_async(shutdown_after_session_creation_never_claims_or_starts_body);
}

async fn shutdown_after_session_creation_never_claims_or_starts_body() {
    let fixture = remote_executor_fixture(1).await;
    let (origin, revision) = git_repository(fixture._temp.path());
    configure_checkout(&fixture.db, &origin).await;
    let now = Utc::now();
    let offered_at =
        (now - ChronoDuration::seconds(2)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
    let claimed_at =
        (now - ChronoDuration::seconds(1)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
    let mut request = request_for_revision(&fixture.request, &revision);
    request.deadline_at =
        (now + ChronoDuration::minutes(10)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
    request.request_sha256.clear();
    let request = request.seal().expect("seal live executor offer");
    let accepted = match fixture
        .db
        .accept_task_board_remote_assignment_offer(
            &request,
            REMOTE_EXECUTOR_PRINCIPAL,
            EXECUTOR_INSTANCE,
            &offered_at,
        )
        .await
        .expect("accept live executor offer")
    {
        TaskBoardRemoteOfferOutcome::Created(record) => record,
        outcome => panic!("unexpected live executor offer outcome: {outcome:?}"),
    };
    assert!(matches!(
        fixture
            .db
            .claim_task_board_remote_assignment(
                &remote_executor_claim_request(&request, &accepted),
                REMOTE_EXECUTOR_PRINCIPAL,
                &claimed_at,
            )
            .await
            .expect("claim live executor offer"),
        TaskBoardRemoteMutationOutcome::Updated(_)
    ));
    let authority = fixture
        .db
        .claim_task_board_remote_executor_start_authority(
            &accepted.assignment_id,
            EXECUTOR_INSTANCE,
            &claimed_at,
        )
        .await
        .expect("claim live start authority")
        .expect("live start remains authorized");
    let barrier = install_remote_session_creation_barrier(&authority.sha256);
    test_seam::reset_counters();
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let loop_handle = spawn_task_board_remote_executor_loop(
        executor_state(&fixture.db, EXECUTOR_INSTANCE),
        Duration::from_secs(60),
        shutdown_rx,
    );

    barrier.wait_until_entered().await;
    shutdown_tx.send(true).expect("observe executor shutdown");
    barrier.release().await;
    loop_handle.await.expect("join executor loop");

    let observed = load_assignment(&fixture.db, &accepted.assignment_id).await;
    assert_eq!(
        test_seam::provision_calls(),
        1,
        "session creation reached the fence"
    );
    assert_eq!(
        test_seam::start_calls(),
        0,
        "shutdown blocks external Start"
    );
    assert!(observed.executor_start_io_permit_sha256.is_none());
    assert!(
        fixture
            .db
            .codex_run(
                &remote_executor_identity(&observed)
                    .expect("run identity")
                    .run_id
            )
            .await
            .expect("load deterministic run")
            .is_none()
    );
}
