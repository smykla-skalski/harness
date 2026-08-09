use std::future::Future;

use super::disabled_tests::{
    EXECUTOR_INSTANCE, configure_checkout, executor_session_count, executor_state, git_repository,
    load_assignment, request_for_revision,
};
use super::test_seam::{self, RuntimeSeamAction, RuntimeSeamCall};
use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db::{
    REMOTE_EXECUTOR_PRINCIPAL, RemoteExecutorFixture, TaskBoardRemoteAssignmentRecord,
    TaskBoardRemoteMutationOutcome, TaskBoardRemoteOfferOutcome, remote_executor_claim_request,
    remote_executor_fixture, remote_executor_identity,
};
use crate::daemon::protocol::CodexRunStatus;
use crate::daemon::serve::test_support::{
    RuntimeSeamScope, install_deterministic_runtime_seam, reconcile_task_board_remote_executor_tick,
};
use crate::task_board::remote_wire::wire::{
    RemoteAssignmentWireState, RemoteSettledRequest, RemoteWorkOwnerBinding,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardLocalAttemptResult, TaskBoardPhaseVerdict, TaskBoardRemoteAssignmentState,
    TaskBoardReviewResult, TaskBoardReviewerOutcome,
};
use chrono::{Duration, SecondsFormat, Utc};
use harness_daemon_db_queries::AsyncAgentWorkingCopyQueries;
use sqlx::query_scalar;

#[test]
fn production_tick_uses_the_runtime_seam_for_start_then_active_probe() {
    run_deep_async(production_tick_uses_the_runtime_seam_for_start_then_active_probe_body);
}

async fn production_tick_uses_the_runtime_seam_for_start_then_active_probe_body() {
    let (fixture, before) = Box::pin(live_claimed_executor()).await;
    let offer = before
        .require_offer()
        .expect("sealed executor offer")
        .clone();
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
    assert!(
        scope
            .arm_completed(&identity.run_id, "discarded duplicate final message".into())
            .await
            .is_err()
    );
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
        load_assignment(&fixture.db, &before.assignment_id)
            .await
            .state,
        TaskBoardRemoteAssignmentState::Completed
    );
    drop(scope);
    assert!(!test_seam::runtime_seam_installed());
}

#[test]
fn workspace_owned_remote_start_creates_no_session_and_reuses_one_authoritative_run() {
    run_deep_async(workspace_owned_remote_start_creates_no_session_body);
}

async fn workspace_owned_remote_start_creates_no_session_body() {
    let (fixture, before) = Box::pin(live_claimed_executor_for_owner("codex", true)).await;
    let offer = before.require_offer().expect("sealed executor offer");
    let owner = offer.work_owner.as_ref().expect("workspace owner");
    let identity = remote_executor_identity(&before).expect("deterministic executor identity");
    let state = executor_state(&fixture.db, EXECUTOR_INSTANCE);
    let scope: RuntimeSeamScope = install_deterministic_runtime_seam().await;

    reconcile_task_board_remote_executor_tick(&state)
        .await
        .expect("start workspace-owned remote worker");
    assert_eq!(executor_session_count(&fixture.db).await, 0);
    let copy = fixture
        .db
        .load_agent_working_copy(&identity.working_copy_id)
        .await
        .expect("load executor working copy")
        .expect("executor working copy");
    assert!(!copy.released);
    let run = fixture
        .db
        .codex_run(&identity.run_id)
        .await
        .expect("load workspace-owned run")
        .expect("workspace-owned run");
    assert_eq!(run.session_id, copy.workspace_id);
    let started = load_assignment(&fixture.db, &before.assignment_id).await;
    let receipt = started.start_receipt.expect("workspace start receipt");
    assert_eq!(
        receipt.workspace_id.as_deref(),
        Some(copy.workspace_id.as_str())
    );
    assert_eq!(
        receipt.working_copy_id.as_deref(),
        Some(identity.working_copy_id.as_str())
    );
    assert_eq!(
        receipt.managed_agent_id.as_deref(),
        Some(identity.run_id.as_str())
    );
    let assignments = query_scalar::<_, String>(
        "SELECT assignment_id FROM agent_workspace_members
         WHERE workspace_id = ?1 AND managed_agent_id = ?2",
    )
    .bind(&copy.workspace_id)
    .bind(&identity.run_id)
    .fetch_all(fixture.db.pool())
    .await
    .expect("load executor workspace member");
    assert_eq!(assignments, vec![owner.work_item_id.clone()]);

    reconcile_task_board_remote_executor_tick(&state)
        .await
        .expect("reconnect probes the authoritative worker");
    assert_eq!(scope.start_count().await, 1);
    assert_eq!(executor_session_count(&fixture.db).await, 0);

    settle_workspace_owned_run(
        &fixture,
        &before,
        &identity,
        &state,
        &scope,
        &copy.worktree_path,
    )
    .await;
}

async fn settle_workspace_owned_run(
    fixture: &RemoteExecutorFixture,
    before: &TaskBoardRemoteAssignmentRecord,
    identity: &crate::daemon::db::TaskBoardRemoteExecutorIdentity,
    state: &crate::daemon::http::DaemonHttpState,
    scope: &RuntimeSeamScope,
    worktree_path: &str,
) {
    scope
        .arm_completed(&identity.run_id, completed_message(before))
        .await
        .expect("arm workspace-owned completion");
    reconcile_task_board_remote_executor_tick(state)
        .await
        .expect("persist workspace-owned terminal result");
    let completed = load_assignment(&fixture.db, &before.assignment_id).await;
    assert_eq!(completed.state, TaskBoardRemoteAssignmentState::Completed);
    let offer = completed
        .require_offer()
        .expect("completed workspace offer");
    let settlement = RemoteSettledRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: completed.lease_id.clone().expect("settlement lease"),
        offer_request_sha256: offer.request_sha256.clone(),
        terminal_state: RemoteAssignmentWireState::Completed,
        result_sha256: completed.result_sha256.clone(),
        request_sha256: String::new(),
    }
    .seal()
    .expect("seal workspace settlement");
    fixture
        .db
        .settle_task_board_remote_assignment(
            &settlement,
            REMOTE_EXECUTOR_PRINCIPAL,
            &crate::workspace::utc_now(),
        )
        .await
        .expect("persist workspace settlement");

    reconcile_task_board_remote_executor_tick(state)
        .await
        .expect("release workspace-owned executor state");
    let cleaned = load_assignment(&fixture.db, &before.assignment_id).await;
    assert!(cleaned.cleanup_completed_at.is_some());
    let copy = fixture
        .db
        .load_agent_working_copy(&identity.working_copy_id)
        .await
        .expect("reload released executor working copy")
        .expect("released executor working copy remains auditable");
    assert!(copy.released);
    assert!(!std::path::Path::new(worktree_path).exists());
    assert_eq!(executor_session_count(&fixture.db).await, 0);

    reconcile_task_board_remote_executor_tick(state)
        .await
        .expect("replay completed workspace cleanup");
    assert_eq!(scope.start_count().await, 1);
}

#[test]
fn workspace_owned_openrouter_start_binds_the_same_sessionless_owner() {
    run_deep_async(workspace_owned_openrouter_start_binds_owner_body);
}

async fn workspace_owned_openrouter_start_binds_owner_body() {
    let (fixture, before) = Box::pin(live_claimed_executor_for_owner("openrouter", true)).await;
    let identity = remote_executor_identity(&before).expect("deterministic executor identity");
    let state = executor_state(&fixture.db, EXECUTOR_INSTANCE);
    let scope: RuntimeSeamScope = install_deterministic_runtime_seam().await;

    reconcile_task_board_remote_executor_tick(&state)
        .await
        .expect("start workspace-owned OpenRouter worker");
    let copy = fixture
        .db
        .load_agent_working_copy(&identity.working_copy_id)
        .await
        .expect("load OpenRouter working copy")
        .expect("OpenRouter working copy");
    let run = fixture
        .db
        .agent_turn_run(&identity.run_id)
        .await
        .expect("load workspace-owned OpenRouter run")
        .expect("workspace-owned OpenRouter run");
    assert_eq!(run.session_id.as_deref(), Some(copy.workspace_id.as_str()));
    assert_eq!(executor_session_count(&fixture.db).await, 0);

    reconcile_task_board_remote_executor_tick(&state)
        .await
        .expect("reconnect probes the authoritative OpenRouter worker");
    assert_eq!(scope.start_count().await, 1);
    assert_eq!(executor_session_count(&fixture.db).await, 0);
}

#[test]
fn openrouter_start_is_durable_and_restart_settles_once_without_codex_run() {
    run_deep_async(openrouter_start_is_durable_and_restart_settles_once_body);
}

async fn openrouter_start_is_durable_and_restart_settles_once_body() {
    let (fixture, before) = Box::pin(live_claimed_executor_for("openrouter")).await;
    let identity = remote_executor_identity(&before).expect("deterministic executor identity");
    let state = executor_state(&fixture.db, EXECUTOR_INSTANCE);
    let scope: RuntimeSeamScope = install_deterministic_runtime_seam().await;

    reconcile_task_board_remote_executor_tick(&state)
        .await
        .expect("start OpenRouter through the remote runtime seam");
    let run = fixture
        .db
        .agent_turn_run(&identity.run_id)
        .await
        .expect("load OpenRouter run")
        .expect("durable OpenRouter run");
    assert_eq!(run.requested_runtime, "openrouter");
    assert_eq!(run.actual_runtime.as_deref(), Some("openrouter"));
    assert!(
        fixture
            .db
            .codex_run(&identity.run_id)
            .await
            .expect("check Codex store")
            .is_none()
    );
    assert_eq!(scope.calls().await.len(), 1);

    assert_eq!(
        fixture
            .db
            .reconcile_interrupted_agent_turn_runs()
            .await
            .expect("preserve correlated OpenRouter run"),
        0
    );
    drop(scope);
    reconcile_task_board_remote_executor_tick(&state)
        .await
        .expect("settle the turn evicted from the restarted runtime");
    assert_eq!(
        load_assignment(&fixture.db, &before.assignment_id)
            .await
            .state,
        TaskBoardRemoteAssignmentState::Failed
    );
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
    offer: &crate::task_board::remote_wire::wire::RemoteOfferRequest,
    identity: &crate::daemon::db::TaskBoardRemoteExecutorIdentity,
) {
    assert_eq!(call.offer, *offer);
    assert_eq!(call.identity, *identity);
    assert!(call.workspace.is_dir());
}

fn completed_message(record: &TaskBoardRemoteAssignmentRecord) -> String {
    let binding = &record
        .require_offer()
        .expect("sealed executor offer")
        .binding;
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
                structured_findings: Vec::new(),
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
    live_claimed_executor_for("codex").await
}

async fn live_claimed_executor_for(
    runtime: &str,
) -> (RemoteExecutorFixture, TaskBoardRemoteAssignmentRecord) {
    live_claimed_executor_for_owner(runtime, false).await
}

async fn live_claimed_executor_for_owner(
    runtime: &str,
    workspace_owned: bool,
) -> (RemoteExecutorFixture, TaskBoardRemoteAssignmentRecord) {
    let fixture = remote_executor_fixture(1).await;
    let (origin, revision) = git_repository(fixture.temp_dir.path());
    configure_checkout(&fixture.db, &origin).await;
    let now = Utc::now();
    let offered_at = (now - Duration::seconds(2)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
    let claimed_at = (now - Duration::seconds(1)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
    let mut request = request_for_revision(&fixture.request, &revision);
    request.launch.runtime = runtime.into();
    if workspace_owned {
        request.work_owner = Some(RemoteWorkOwnerBinding {
            source_daemon_id: "source-daemon-a".into(),
            workspace_id: "source-workspace-a".into(),
            working_copy_id: "source-copy-a".into(),
            work_item_id: "source-work-item-a".into(),
            managed_agent_id: request.binding.idempotency_key.clone(),
        });
    }
    request.deadline_at =
        (now + Duration::minutes(10)).to_rfc3339_opts(SecondsFormat::AutoSi, true);
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
