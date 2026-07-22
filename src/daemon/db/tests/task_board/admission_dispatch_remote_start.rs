use super::completion_evidence_tests::{
    accepted_offer, configure_remote_controller, intent_status, read_only_launch, remote_offer,
    remote_status, remote_status_request,
};
use super::*;
use crate::daemon::db::task_board::remote_assignment_test_support::claim_request;
use crate::daemon::db::task_board::{TaskBoardRemoteOfferOutcome, TaskBoardRemoteOperationKind};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteOfferRequest,
};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TASK_BOARD_REMOTE_PROTOCOL_VERSION,
    TaskBoardExecutionHostAdvertisement, TaskBoardFailureClass, TaskBoardPhaseCapabilityProfile,
    TaskBoardWorkflowExecutionCas,
};

#[path = "admission_dispatch_remote_start_fixture.rs"]
mod fixture;
pub(crate) use fixture::{PreparedRemoteOffer, prepare_remote_offer};
pub(super) use fixture::{prepare_remote_offer_with_policy, prepare_remote_offer_with_retry};

#[tokio::test]
async fn started_terminal_observation_keeps_committed_admission_and_remote_parent() {
    for state in [
        RemoteAssignmentWireState::Failed,
        RemoteAssignmentWireState::Superseded,
    ] {
        let prepared = prepare_remote_offer_with_policy("admission-remote-terminal", true).await;
        persist_remote_start(&prepared).await;
        let parent = prepared
            .db
            .task_board_workflow_execution(&prepared.execution_id)
            .await
            .expect("load parent before terminal observation")
            .expect("parent before terminal observation");
        let response = terminal_status(&prepared.offer, state, true);
        prepared
            .db
            .record_task_board_remote_assignment_status(
                &remote_status_request(&prepared.offer),
                &response,
                "executor-a",
            )
            .await
            .expect("record started terminal status");
        assert_eq!(
            intent_status(&prepared.db, &prepared.intent).await,
            "completed"
        );
        assert_eq!(
            ledger_kind_state(&prepared.db, &prepared.intent, "rate").await,
            "committed"
        );
        assert_eq!(
            ledger_kind_state(&prepared.db, &prepared.intent, "concurrency").await,
            "committed"
        );
        assert_eq!(
            prepared
                .db
                .task_board_workflow_execution(&prepared.execution_id)
                .await
                .expect("load parent after terminal observation")
                .expect("parent after terminal observation"),
            parent
        );
        assert!(
            !prepared
                .db
                .complete_task_board_workflow_dispatch_start(&prepared.execution_id)
                .await
                .expect("terminal status already settled prepared start")
        );
        let sequence = prepared
            .db
            .current_change_sequence()
            .await
            .expect("load change sequence");
        prepared
            .db
            .record_task_board_remote_assignment_status(
                &remote_status_request(&prepared.offer),
                &response,
                "executor-a",
            )
            .await
            .expect("replay terminal status");
        assert_eq!(
            prepared
                .db
                .current_change_sequence()
                .await
                .expect("load replay sequence"),
            sequence
        );
    }
}

#[tokio::test]
async fn terminal_before_remote_start_keeps_prepared_admission_reserved() {
    let prepared = prepare_remote_offer_with_policy("admission-remote-unstarted", true).await;
    offer_remote(&prepared, "2026-07-19T10:00:00Z", "2026-07-19T10:01:00Z")
        .await
        .expect("offer remote assignment");
    prepared
        .db
        .claim_task_board_remote_offer_io_authority(
            &prepared.offer,
            "executor-a",
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("claim offer I/O authority")
        .expect("offer remains active");
    prepared
        .db
        .record_task_board_remote_offer_response(
            &accepted_offer(&prepared.offer),
            "executor-a",
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("record accepted offer");
    let before = prepared
        .db
        .task_board_item_snapshot("admission-remote-unstarted")
        .await
        .expect("load item before terminal status")
        .item_revision;
    let parent = prepared
        .db
        .task_board_workflow_execution(&prepared.execution_id)
        .await
        .expect("load parent before terminal observation")
        .expect("parent before terminal observation");
    let response = terminal_status(&prepared.offer, RemoteAssignmentWireState::Cancelled, false);
    prepared
        .db
        .record_task_board_remote_assignment_status(
            &remote_status_request(&prepared.offer),
            &response,
            "executor-a",
        )
        .await
        .expect("record unstarted terminal status");
    assert_eq!(
        intent_status(&prepared.db, &prepared.intent).await,
        "workflow_prepared"
    );
    assert_eq!(
        ledger_kind_state(&prepared.db, &prepared.intent, "rate").await,
        "reserved"
    );
    assert_eq!(
        ledger_kind_state(&prepared.db, &prepared.intent, "concurrency").await,
        "reserved"
    );
    let after = prepared
        .db
        .task_board_item_snapshot("admission-remote-unstarted")
        .await
        .expect("load item after terminal status")
        .item_revision;
    assert_eq!(after, before);
    assert_eq!(
        prepared
            .db
            .task_board_workflow_execution(&prepared.execution_id)
            .await
            .expect("load parent after terminal observation")
            .expect("parent after terminal observation"),
        parent
    );
    let sequence = prepared
        .db
        .current_change_sequence()
        .await
        .expect("load terminal sequence");
    prepared
        .db
        .record_task_board_remote_assignment_status(
            &remote_status_request(&prepared.offer),
            &response,
            "executor-a",
        )
        .await
        .expect("replay unstarted terminal status");
    assert_eq!(
        prepared
            .db
            .current_change_sequence()
            .await
            .expect("load replay sequence"),
        sequence
    );
}

#[tokio::test]
async fn remote_start_keeps_the_unconfigured_admission_frozen_after_policy_enablement() {
    let prepared = prepare_remote_offer("admission-remote-unconfigured").await;
    persist_remote_start(&prepared).await;
    let PreparedRemoteOffer {
        db,
        intent,
        execution_id,
        ..
    } = prepared;
    assert_eq!(
        frozen_start_admission(&db, &intent).await,
        Some("unconfigured".into())
    );
    assert_eq!(intent_status(&db, &intent).await, "completed");

    configure_policy(&db, admission_policy(1)).await;
    assert!(
        !db.complete_task_board_workflow_dispatch_start(&execution_id)
            .await
            .expect("replay atomically completed unconfigured start")
    );
    assert_eq!(intent_status(&db, &intent).await, "completed");
}

#[tokio::test]
async fn unavailable_offer_does_not_freeze_unconfigured_admission_authority() {
    let prepared = prepare_remote_offer("admission-remote-unavailable").await;
    record_host_load(&prepared.db, 1, "2026-07-19T10:00:00Z").await;
    assert!(matches!(
        offer_remote(&prepared, "2026-07-19T10:00:00Z", "2026-07-19T10:01:00Z")
            .await
            .expect("reject unavailable controller host"),
        TaskBoardRemoteOfferOutcome::Unavailable
    ));
    assert_eq!(
        frozen_start_admission(&prepared.db, &prepared.intent).await,
        None
    );

    configure_policy(&prepared.db, admission_policy(1)).await;
    let blocker = create_plan(
        &prepared.db,
        "admission-remote-blocker",
        AgentMode::Headless,
    )
    .await;
    prepared
        .db
        .reserve_task_board_dispatch(&blocker, "control-plane", Some("/tmp/project"), false)
        .await
        .expect("reserve blocking admission");
    record_host_load(&prepared.db, 0, "2026-07-19T10:00:01Z").await;
    let error = offer_remote(&prepared, "2026-07-19T10:00:02Z", "2026-07-19T10:01:02Z")
        .await
        .expect_err("changed admission settings must block a later target");
    assert!(error.to_string().contains("workflow revision changed"));
    assert_eq!(
        frozen_start_admission(&prepared.db, &prepared.intent).await,
        None
    );
    let execution = prepared
        .db
        .task_board_workflow_execution(&prepared.execution_id)
        .await
        .expect("load blocked execution")
        .expect("execution");
    assert!(
        execution
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .is_none()
    );
    assert!(
        execution
            .ownership
            .resources
            .contains_key("admission_owner")
    );
}

async fn configured_remote_test_db(
    configure_admission: bool,
    retry_max_attempts: Option<u32>,
) -> TestDb {
    let db = test_db().await;
    if let Some(max_attempts) = retry_max_attempts {
        let mut settings = db
            .task_board_orchestrator_settings()
            .await
            .expect("load retry settings");
        settings.retry.max_attempts = max_attempts;
        db.replace_task_board_orchestrator_settings(&settings)
            .await
            .expect("configure retry attempts");
    }
    configure_remote_controller(&db).await;
    if configure_admission {
        configure_policy(&db, admission_policy(1)).await;
    }
    db
}

fn terminal_status(
    offer: &RemoteOfferRequest,
    state: RemoteAssignmentWireState,
    started: bool,
) -> crate::daemon::task_board_remote_transport::wire::RemoteStatusResponse {
    let mut response = remote_status(offer, RemoteAssignmentWireState::Running, started);
    response.state = state;
    response.status_sha256.clear();
    response.error_code = Some("remote_terminal".into());
    response.failure_class =
        (state == RemoteAssignmentWireState::Failed).then_some(TaskBoardFailureClass::Permanent);
    response.observed_at = "2026-07-19T10:00:05Z".into();
    response.seal().expect("seal terminal status")
}

pub(super) async fn persist_remote_start(prepared: &PreparedRemoteOffer) {
    offer_remote(prepared, "2026-07-19T10:00:00Z", "2026-07-19T10:01:00Z")
        .await
        .expect("offer remote assignment and freeze admission");
    prepared
        .db
        .claim_task_board_remote_offer_io_authority(
            &prepared.offer,
            "executor-a",
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("claim offer I/O authority")
        .expect("remote offer stays active");
    prepared
        .db
        .record_task_board_remote_offer_response(
            &accepted_offer(&prepared.offer),
            "executor-a",
            "2026-07-19T10:00:01Z",
        )
        .await
        .expect("record accepted offer");
    // Grant the claim I/O authority (its response is treated as lost) so the Running
    // status reconstructs the claim and durably confirms the start.
    let accepted = prepared
        .db
        .task_board_remote_assignment(&prepared.offer.binding.assignment_id)
        .await
        .expect("load accepted assignment")
        .expect("accepted assignment");
    let claim = claim_request(&prepared.offer, &accepted);
    prepared
        .db
        .claim_task_board_remote_claim_io_authority(&claim, "executor-a", "2026-07-19T10:00:01Z")
        .await
        .expect("claim remote claim authority")
        .expect("claim remains active");
    prepared
        .db
        .complete_task_board_remote_operation_trust(
            &prepared.offer.binding.assignment_id,
            TaskBoardRemoteOperationKind::Claim,
            &claim.request_sha256,
        )
        .await
        .expect("release completed claim transport trust");
    prepared
        .db
        .record_task_board_remote_assignment_status(
            &remote_status_request(&prepared.offer),
            &remote_status(&prepared.offer, RemoteAssignmentWireState::Running, true),
            "executor-a",
        )
        .await
        .expect("record exact remote start evidence");
}

pub(super) async fn offer_remote(
    prepared: &PreparedRemoteOffer,
    offered_at: &str,
    lease_expires_at: &str,
) -> Result<TaskBoardRemoteOfferOutcome, crate::errors::CliError> {
    prepared
        .db
        .offer_task_board_remote_assignment(
            &TaskBoardWorkflowExecutionCas::from(&prepared.execution),
            &crate::task_board::TaskBoardExecutionAttemptCas::from(&prepared.attempt),
            &prepared.offer,
            "executor-a",
            offered_at,
            lease_expires_at,
            "2026-07-19T10:10:00Z",
        )
        .await
}

async fn record_host_load(db: &AsyncDaemonDb, active_assignments: u32, observed_at: &str) {
    db.record_task_board_execution_host_observation(
        &TaskBoardExecutionHostAdvertisement {
            host_id: "executor-a".into(),
            host_instance_id: "instance-a".into(),
            protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
            repositories: vec!["example/harness".into()],
            runtimes: vec!["codex".into()],
            capabilities: vec![TaskBoardPhaseCapabilityProfile::ReviewReadOnly],
            capacity: 1,
            active_assignments,
            heartbeat_at: observed_at.into(),
        },
        observed_at,
    )
    .await
    .expect("record remote host load");
}

async fn frozen_start_admission(db: &AsyncDaemonDb, intent_id: &str) -> Option<String> {
    sqlx::query_scalar(
        "SELECT start_admission_outcome FROM task_board_dispatch_intents WHERE intent_id = ?1",
    )
    .bind(intent_id)
    .fetch_one(db.pool())
    .await
    .expect("load frozen start admission")
}
