use std::future::Future;

use super::disabled_tests::{
    EXECUTOR_INSTANCE, configure_checkout, executor_state, git_repository, load_assignment,
    request_for_revision,
};
use super::test_seam::{self, RuntimeSeamAction, RuntimeSeamCall};
use chrono::{Duration, SecondsFormat, Utc};
use crate::daemon::db::{
    REMOTE_EXECUTOR_PRINCIPAL, RemoteExecutorFixture, TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome, remote_executor_claim_request,
    remote_executor_fixture, remote_executor_identity,
};
use crate::daemon::protocol::CodexRunStatus;
use crate::daemon::service::serve::test_support::{
    RuntimeSeamScope, install_deterministic_runtime_seam,
    reconcile_task_board_remote_executor_tick,
};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardLocalAttemptResult, TaskBoardPhaseVerdict, TaskBoardReviewResult,
    TaskBoardRemoteAssignmentState, TaskBoardReviewerOutcome,
};

#[test]
fn production_tick_uses_the_runtime_seam_for_start_then_active_probe() {
    run_deep_async(production_tick_uses_the_runtime_seam_for_start_then_active_probe_body);
}

async fn production_tick_uses_the_runtime_seam_for_start_then_active_probe_body() {
    let (fixture, before) = live_claimed_executor().await;
    let offer = before.require_offer().expect("sealed executor offer").clone();
    let identity = remote_executor_identity(&before).expect("deterministic executor identity");
    let state = executor_state(&fixture.db, EXECUTOR_INSTANCE);
    let scope: RuntimeSeamScope = install_deterministic_runtime_seam().await;

    reconcile_task_board_remote_executor_tick(&state)
        .await
        .expect("first production tick starts through the runtime seam");
    let first = scope.calls().await;
    assert_eq!(first.len(), 1);
    assert_runtime_context(&first[0], &offer, &identity);
    assert!(matches!(&first[0].action, RuntimeSeamAction::Start { .. }));

    reconcile_task_board_remote_executor_tick(&state)
        .await
        .expect("second production tick probes the active seam run");
    let second = scope.calls().await;
    assert_eq!(second.len(), 2);
    assert_runtime_context(&second[1], &offer, &identity);
    assert!(matches!(&second[1].action, RuntimeSeamAction::Probe { .. }));
    assert_eq!(
        fixture
            .db
            .codex_run(&identity.run_id)
            .await
            .expect("load active Probe evidence")
            .expect("seam Probe preserves the run")
            .status,
        CodexRunStatus::Running
    );

    let final_message = completed_message(&before);
    scope
        .arm_completed(&identity.run_id, final_message.clone())
        .await
        .expect("arm the exact deterministic run");
    assert!(scope
        .arm_completed(&identity.run_id, "discarded duplicate final message".into())
        .await
        .is_err());
    reconcile_task_board_remote_executor_tick(&state)
        .await
        .expect("third production tick persists terminal seam evidence");
    let third = scope.calls().await;
    assert_eq!(third.len(), 3);
    assert_runtime_context(&third[2], &offer, &identity);
    assert!(matches!(&third[2].action, RuntimeSeamAction::Probe { .. }));
    assert_eq!(
        fixture
            .db
            .codex_run(&identity.run_id)
            .await
            .expect("load completed Probe evidence")
            .expect("seam terminal Probe persists the run")
            .status,
        CodexRunStatus::Completed
    );
    assert_eq!(
        fixture
            .db
            .codex_run(&identity.run_id)
            .await
            .expect("reload completed Probe evidence")
            .expect("completed run remains durable")
            .final_message
            .as_deref(),
        Some(final_message.as_str())
    );
    assert_eq!(
        load_assignment(&fixture.db, &before.assignment_id).await.state,
        TaskBoardRemoteAssignmentState::Completed
    );
    drop(scope);
    assert!(!test_seam::runtime_seam_installed());
}

#[test]
fn runtime_seam_scope_clears_on_early_return_and_panic() {
    run_deep_async(runtime_seam_scope_clears_on_early_return_and_panic_body);
}

async fn runtime_seam_scope_clears_on_early_return_and_panic_body() {
    install_and_return().await;
    assert!(!test_seam::runtime_seam_installed());

    let panic = tokio::spawn(async {
        let _scope = test_seam::install_deterministic_runtime_seam().await;
        panic!("test deterministic runtime seam cleanup");
    })
    .await
    .expect_err("seam task must panic");
    assert!(panic.is_panic());
    assert!(!test_seam::runtime_seam_installed());
}

async fn install_and_return() {
    let _scope: RuntimeSeamScope = install_deterministic_runtime_seam().await;
    assert!(test_seam::runtime_seam_installed());
}

fn assert_runtime_context(
    call: &RuntimeSeamCall,
    offer: &crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
    identity: &crate::daemon::db::TaskBoardRemoteExecutorIdentity,
) {
    assert_eq!(call.offer, *offer);
    assert_eq!(call.identity, *identity);
    assert!(call.workspace.is_dir());
}

fn completed_message(record: &TaskBoardRemoteAssignmentRecord) -> String {
    let binding = &record.require_offer().expect("sealed executor offer").binding;
    let head = binding
        .expected_head_revision
        .clone()
        .expect("exact executor head revision");
    serde_json::to_string(&TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: binding.execution_id.clone(),
        action_key: binding.action_key.clone(),
        attempt: binding.attempt,
        idempotency_key: binding.idempotency_key.clone(),
        exact_head_revision: head.clone(),
        artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
            profile_id: binding
                .action_key
                .strip_prefix("review:")
                .expect("review action key contains its exact profile")
                .into(),
            result: TaskBoardReviewResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                head_revision: head,
                summary: "deterministic completed Probe".into(),
                findings: Vec::new(),
            },
        }),
    })
    .expect("serialize canonical deterministic result")
}

fn run_deep_async<F>(build: impl FnOnce() -> F + Send + 'static)
where
    F: Future<Output = ()>,
{
    std::thread::Builder::new()
        .stack_size(32 * 1024 * 1024)
        .spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("build deep runtime seam test runtime")
                .block_on(build());
        })
        .expect("spawn deep runtime seam test thread")
        .join()
        .expect("join deep runtime seam test thread");
}

async fn live_claimed_executor() -> (RemoteExecutorFixture, TaskBoardRemoteAssignmentRecord) {
    let fixture = remote_executor_fixture(1).await;
    let (origin, revision) = git_repository(fixture._temp.path());
    configure_checkout(&fixture.db, &origin).await;
    let now = Utc::now();
    let offered_at = (now - Duration::seconds(2)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
    let claimed_at = (now - Duration::seconds(1)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
    let mut request = request_for_revision(&fixture.request, &revision);
    request.deadline_at = (now + Duration::minutes(10)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
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
    let claimed = load_assignment(&fixture.db, &accepted.assignment_id).await;
    (fixture, claimed)
}
