use std::future::Future;

use super::super::with_test_remote_tls_root;
use super::fixture::{
    AcceptanceFixture, HOST_INSTANCE, REPOSITORY, TOKEN, TOKEN_ENV, TlsRouterServer, assignment,
    git,
};
use crate::daemon::db::remote_executor_identity;
use crate::daemon::service::task_board_remote_controller::drive_task_board_remote_controller;
use crate::daemon::service::{
    install_deterministic_runtime_seam, reconcile_task_board_remote_executor_tick,
};
use crate::daemon::task_board_remote_transport::controller_authority_test_support::test_tls_material;
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardExecutionState, TaskBoardImplementationResult, TaskBoardLocalAttemptResult,
    TaskBoardRemoteAssignmentState,
};

#[test]
fn default_task_implementation_cross_daemon_lifecycle_imports_and_cleans_up() {
    run_deep_acceptance_async(
        default_task_implementation_cross_daemon_lifecycle_imports_and_cleans_up_body,
    );
}

async fn default_task_implementation_cross_daemon_lifecycle_imports_and_cleans_up_body() {
    let tls = test_tls_material();
    with_test_remote_tls_root(tls.ca_der(), &[(TOKEN_ENV, TOKEN)], async {
        let data = tempfile::tempdir().expect("isolated acceptance data root");
        let data_path = data.path().to_string_lossy().into_owned();
        temp_env::async_with_vars(
            [
                ("XDG_DATA_HOME", Some(data_path.as_str())),
                ("CLAUDE_SESSION_ID", Some("remote-acceptance-lifecycle")),
            ],
            async {
                run_default_task_implementation_lifecycle(&tls).await;
            },
        )
        .await;
    })
    .await;
}

fn run_deep_acceptance_async<F>(build: impl FnOnce() -> F + Send + 'static)
where
    F: Future<Output = ()> + 'static,
{
    std::thread::Builder::new()
        .stack_size(32 * 1024 * 1024)
        .spawn(move || {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .thread_stack_size(32 * 1024 * 1024)
                .enable_all()
                .build()
                .expect("build acceptance runtime")
                .block_on(build());
        })
        .expect("spawn deep acceptance test thread")
        .join()
        .expect("join deep acceptance test thread");
}

async fn run_default_task_implementation_lifecycle(
    tls: &crate::daemon::task_board_remote_transport::controller_authority_test_support::TestTlsMaterial,
) {
    let fixture = AcceptanceFixture::new();
    let executor = fixture.executor_state(HOST_INSTANCE, true).await;
    let executor_db = executor.async_db.get().expect("executor async database");
    let server = TlsRouterServer::start(executor.clone(), tls.server_config()).await;
    let controller = fixture.controller_state("controller-acceptance-a");
    fixture
        .configure_controller(&controller, server.endpoint(), tls)
        .await;
    let controller_db = controller
        .async_db
        .get()
        .expect("controller async database");
    let seeded = fixture.seed_default_task(controller_db).await;
    let claimed = offer_and_claim(controller_db, &seeded.execution_id).await;
    let result = execute_implementation(&executor, executor_db, &claimed, &seeded).await;
    settle_and_clean_up(controller_db, &executor, &seeded.execution_id).await;
    assert_completion(
        controller_db,
        executor_db,
        &fixture,
        &seeded,
        &claimed.assignment_id,
        &result,
    )
    .await;
    server.stop().await;
}

struct ExecutorResult {
    session_id: String,
    result_head: String,
}

async fn offer_and_claim(
    controller_db: &crate::daemon::db::AsyncDaemonDb,
    execution_id: &str,
) -> crate::daemon::db::TaskBoardRemoteAssignmentRecord {
    drive(controller_db, "offer candidate").await;
    let offered = assignment(controller_db, execution_id).await;
    assert_eq!(offered.state, TaskBoardRemoteAssignmentState::Offered);
    assert_eq!(
        offered.target_host_instance_id.as_deref(),
        Some(HOST_INSTANCE)
    );
    assert!(
        offered
            .require_offer()
            .expect("sealed offer")
            .source
            .requires_upload()
    );
    drive(controller_db, "upload source and offer executor").await;
    drive(controller_db, "claim accepted executor offer").await;
    let claimed = assignment(controller_db, execution_id).await;
    assert_eq!(claimed.state, TaskBoardRemoteAssignmentState::Claimed);
    assert!(claimed.claim_receipt.is_some());
    claimed
}

async fn execute_implementation(
    executor: &crate::daemon::http::DaemonHttpState,
    executor_db: &crate::daemon::db::AsyncDaemonDb,
    claimed: &crate::daemon::db::TaskBoardRemoteAssignmentRecord,
    seeded: &super::fixture::SeededExecution,
) -> ExecutorResult {
    let seam = install_deterministic_runtime_seam().await;
    reconcile_executor_tick(executor, "acquire authority and reconcile source workspace").await;
    let first = executor_assignment(executor_db, &claimed.assignment_id).await;
    let identity = remote_executor_identity(&first).expect("first executor identity");
    assert_initial_start_boundary(executor_db, &first, &identity).await;
    reconcile_executor_tick(executor, "reconcile permit and active runtime").await;
    let executor_assignment = executor_assignment(executor_db, &claimed.assignment_id).await;
    let active_identity =
        remote_executor_identity(&executor_assignment).expect("executor identity");
    assert_eq!(active_identity, identity);
    assert_active_start_boundary(executor_db, &executor_assignment, &active_identity).await;
    let workspace = executor_db
        .resolve_session(&active_identity.session_id)
        .await
        .expect("load executor session")
        .expect("executor session exists")
        .state
        .worktree_path;
    assert_eq!(
        git(&workspace, &["rev-parse", "HEAD"]),
        seeded.base_revision
    );
    let result_head = commit_executor_result(&workspace);
    seam.arm_completed(
        &active_identity.run_id,
        serde_json::to_string(&implementation_result(
            &executor_assignment,
            &seeded.base_revision,
            &result_head,
        ))
        .expect("serialize executor implementation result"),
    )
    .await
    .expect("arm deterministic completed runtime");

    reconcile_executor_tick(executor, "persist completed executor result").await;
    ExecutorResult {
        session_id: active_identity.session_id,
        result_head,
    }
}

async fn assert_initial_start_boundary(
    db: &crate::daemon::db::AsyncDaemonDb,
    record: &crate::daemon::db::TaskBoardRemoteAssignmentRecord,
    identity: &crate::daemon::db::TaskBoardRemoteExecutorIdentity,
) {
    if matches!(
        record.state,
        TaskBoardRemoteAssignmentState::Started | TaskBoardRemoteAssignmentState::Running
    ) {
        assert_active_start_boundary(db, record, identity).await;
        return;
    }
    assert_eq!(record.state, TaskBoardRemoteAssignmentState::Claimed);
    assert!(record.executor_start_authority_sha256.is_some());
    assert!(record.executor_start_authority_at.is_some());
    assert!(record.executor_start_io_permit_sha256.is_none());
    assert!(record.executor_start_io_permit_at.is_none());
    assert!(record.start_receipt.is_none());
    assert!(record.workspace_ref.is_none());
    assert!(record.started_at.is_none());
    assert!(
        db.codex_run(&identity.run_id)
            .await
            .expect("load executor runtime")
            .is_none(),
        "pre-Start authority must not have launched Codex"
    );
}

async fn assert_active_start_boundary(
    db: &crate::daemon::db::AsyncDaemonDb,
    record: &crate::daemon::db::TaskBoardRemoteAssignmentRecord,
    identity: &crate::daemon::db::TaskBoardRemoteExecutorIdentity,
) {
    assert!(
        matches!(
            record.state,
            TaskBoardRemoteAssignmentState::Started | TaskBoardRemoteAssignmentState::Running
        ),
        "executor Start has not reached an active state: state={:?}, error={:?}, \
         authority={}, permit={}, receipt={}, workspace={:?}, started_at={:?}",
        record.state,
        record.error.as_deref(),
        record.executor_start_authority_sha256.is_some(),
        record.executor_start_io_permit_sha256.is_some(),
        record.start_receipt.is_some(),
        record.workspace_ref.as_deref(),
        record.started_at.as_deref(),
    );
    assert!(record.start_receipt.is_some());
    assert!(record.workspace_ref.is_some());
    assert!(record.started_at.is_some());
    assert!(record.executor_start_authority_sha256.is_none());
    assert!(record.executor_start_io_permit_sha256.is_none());
    assert!(
        db.codex_run(&identity.run_id)
            .await
            .expect("load executor runtime")
            .is_some(),
        "executor Start must persist its deterministic Codex run"
    );
}

async fn settle_and_clean_up(
    controller_db: &crate::daemon::db::AsyncDaemonDb,
    executor: &crate::daemon::http::DaemonHttpState,
    execution_id: &str,
) {
    drive(controller_db, "observe completed executor result").await;
    assert_import_target_ready(controller_db, execution_id).await;
    drive(controller_db, "import and adopt executor Git result").await;
    drive(controller_db, "settle adopted executor result").await;
    reconcile_executor_tick(executor, "clean up settled executor worktree").await;
    drive(controller_db, "observe executor cleanup").await;
}

async fn assert_import_target_ready(db: &crate::daemon::db::AsyncDaemonDb, execution_id: &str) {
    let assignment = assignment(db, execution_id).await;
    let parent = db
        .task_board_workflow_execution(&assignment.execution_id)
        .await
        .expect("load import target execution")
        .expect("import target execution exists");
    let offer = assignment.require_offer().expect("sealed import offer");
    let attempt = parent
        .attempts
        .iter()
        .find(|attempt| {
            attempt.action_key == offer.binding.action_key
                && attempt.attempt == offer.binding.attempt
                && attempt.idempotency_key == offer.binding.idempotency_key
        })
        .expect("exact import attempt");
    assert_eq!(assignment.state, TaskBoardRemoteAssignmentState::Completed);
    assert_eq!(
        parent.ownership.host_id.as_deref(),
        Some(assignment.host_id.as_str())
    );
    assert_eq!(parent.ownership.fencing_epoch, assignment.fencing_epoch);
    assert!(matches!(
        parent.transition.execution_state,
        TaskBoardExecutionState::Starting | TaskBoardExecutionState::Running
    ));
    assert!(matches!(
        attempt.state,
        crate::task_board::TaskBoardAttemptState::Starting
            | crate::task_board::TaskBoardAttemptState::Running
    ));
    assert_eq!(
        crate::task_board::task_board_remote_execution_target(&parent),
        Some(assignment.assignment_id.as_str())
    );
}

async fn assert_completion(
    controller_db: &crate::daemon::db::AsyncDaemonDb,
    executor_db: &crate::daemon::db::AsyncDaemonDb,
    fixture: &AcceptanceFixture,
    seeded: &super::fixture::SeededExecution,
    assignment_id: &str,
    executor_result: &ExecutorResult,
) {
    let settled = controller_db
        .task_board_remote_assignment(assignment_id)
        .await
        .expect("load settled controller assignment")
        .expect("settled controller assignment exists");
    assert_eq!(settled.state, TaskBoardRemoteAssignmentState::Completed);
    assert!(settled.cleanup_completed_at.is_some());
    let execution = controller_db
        .task_board_workflow_execution(&seeded.execution_id)
        .await
        .expect("load adopted execution")
        .expect("adopted execution exists");
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Running
    );
    assert_eq!(
        execution.transition.exact_head_revision.as_deref(),
        Some(seeded.base_revision.as_str())
    );
    assert!(execution.attempts.iter().any(|attempt| {
        matches!(
            attempt.artifact,
            Some(TaskBoardAttemptResultArtifact::Implementation(ref implementation))
                if implementation.head_revision == executor_result.result_head
        )
    }));
    assert_eq!(
        git(&fixture.controller_worktree, &["rev-parse", "HEAD"]),
        executor_result.result_head
    );
    assert_eq!(
        git(
            &fixture.controller_worktree,
            &["rev-parse", "--abbrev-ref", "HEAD"]
        ),
        format!("harness/{}", seeded.session_id)
    );
    assert!(
        executor_db
            .resolve_session(&executor_result.session_id)
            .await
            .expect("check executor cleanup")
            .is_none()
    );
}

async fn drive(db: &crate::daemon::db::AsyncDaemonDb, phase: &str) {
    let report = Box::pin(drive_task_board_remote_controller(db))
        .await
        .unwrap_or_else(|error| panic!("controller {phase}: {error}"));
    assert!(
        report.failures.is_empty(),
        "controller {phase}: {:?}",
        report.failures
    );
}

async fn reconcile_executor_tick(executor: &crate::daemon::http::DaemonHttpState, phase: &str) {
    reconcile_task_board_remote_executor_tick(executor)
        .await
        .unwrap_or_else(|error| panic!("executor {phase}: {error}"));
}

async fn executor_assignment(
    db: &crate::daemon::db::AsyncDaemonDb,
    assignment_id: &str,
) -> crate::daemon::db::TaskBoardRemoteAssignmentRecord {
    db.task_board_remote_assignment(assignment_id)
        .await
        .expect("load executor assignment")
        .expect("executor assignment exists")
}

fn commit_executor_result(workspace: &std::path::Path) -> String {
    std::fs::write(workspace.join("implemented.txt"), "implemented remotely\n")
        .expect("write executor result");
    git(workspace, &["add", "implemented.txt"]);
    git(workspace, &["commit", "-qm", "implement remote acceptance"]);
    git(workspace, &["rev-parse", "HEAD"])
}

fn implementation_result(
    assignment: &crate::daemon::db::TaskBoardRemoteAssignmentRecord,
    base_revision: &str,
    result_head: &str,
) -> TaskBoardLocalAttemptResult {
    let binding = &assignment
        .require_offer()
        .expect("sealed executor offer")
        .binding;
    assert_eq!(binding.repository, REPOSITORY);
    TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: binding.execution_id.clone(),
        action_key: binding.action_key.clone(),
        attempt: binding.attempt,
        idempotency_key: binding.idempotency_key.clone(),
        exact_head_revision: result_head.into(),
        artifact: TaskBoardAttemptResultArtifact::Implementation(TaskBoardImplementationResult {
            revision_cycle: 1,
            base_head_revision: base_revision.into(),
            head_revision: result_head.into(),
            summary: "Executor committed the accepted implementation.".into(),
            evidence: vec!["remote executor Git commit".into()],
        }),
    }
}
