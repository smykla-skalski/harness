use sqlx::query_scalar;

use super::{RepositoryCase, RepositorySource, seed_repository_case};
use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db::{AgentTurnRunStatus, AsyncDaemonDb};
use crate::daemon::db_open::AsyncDaemonDbConnect;
use crate::daemon::http::tests::support::remote_execution_acceptance::fixture::{
    AcceptanceFixture, HOST_INSTANCE, TlsRouterServer, assignment,
};
use crate::daemon::http::tests::support::remote_execution_acceptance::lifecycle::{
    drive, executor_assignment, reconcile_executor_tick, run_deep_acceptance_async,
    with_acceptance_environment,
};
use crate::daemon::protocol::TaskBoardGetItemRequest;
use crate::daemon::serve::test_support::install_deterministic_runtime_seam;
use crate::daemon::task_board_remote_transport::controller_authority_test_support::{
    TestTlsMaterial, test_tls_material,
};
use crate::task_board::{
    TaskBoardAiReviewReportResponse, TaskBoardExecutionPhase, TaskBoardWorkflowKind,
};

#[test]
fn openrouter_review_uses_agent_turn_store_and_preserves_ticket_runtime_across_restart() {
    run_deep_acceptance_async(|| async {
        let tls = test_tls_material();
        Box::pin(with_acceptance_environment(
            &tls,
            "remote-acceptance-openrouter-runtime",
            run_openrouter_restart_case(&tls),
        ))
        .await;
    });
}

async fn run_openrouter_restart_case(tls: &TestTlsMaterial) {
    let fixture = AcceptanceFixture::new();
    let executor = fixture.executor_state(HOST_INSTANCE, true).await;
    fixture.configure_matrix_executor(&executor).await;
    let server = TlsRouterServer::start(executor.clone(), tls.server_config()).await;
    let controller = fixture.controller_state("controller-openrouter-a");
    fixture
        .configure_matrix_controller(&controller, server.endpoint(), tls)
        .await;
    select_openrouter_reviewer(
        controller
            .async_db
            .get()
            .expect("controller OpenRouter database"),
    )
    .await;
    let case = RepositoryCase {
        name: "openrouter-pr-review",
        workflow: TaskBoardWorkflowKind::PR_REVIEW,
        phase: TaskBoardExecutionPhase::Review,
        source: RepositorySource::Branch,
    };
    let controller_db = controller.async_db.get().expect("controller database");
    let execution_id = Box::pin(seed_repository_case(&fixture, controller_db, &case)).await;
    drive(controller_db, "offer OpenRouter review").await;
    drive(controller_db, "send OpenRouter offer").await;
    drive(controller_db, "claim OpenRouter offer").await;
    let claimed = assignment(controller_db, &execution_id).await;
    assert_eq!(
        claimed.state,
        crate::task_board::TaskBoardRemoteAssignmentState::Claimed
    );
    assert_eq!(
        claimed
            .require_offer()
            .expect("sealed offer")
            .launch
            .runtime,
        "openrouter"
    );

    let seam = install_deterministic_runtime_seam().await;
    reconcile_executor_tick(&executor, "acquire OpenRouter start authority").await;
    reconcile_executor_tick(&executor, "start durable OpenRouter turn").await;
    let executor_db = executor.async_db.get().expect("executor database");
    let executor_record = executor_assignment(executor_db, &claimed.assignment_id).await;
    assert!(
        executor_record.start_receipt.is_some(),
        "executor did not retain durable start receipt: state={:?} error={:?}",
        executor_record.state,
        executor_record.error
    );
    let identity = crate::daemon::db::remote_executor_identity(&executor_record)
        .expect("OpenRouter executor identity");
    let run = executor_db
        .agent_turn_run(&identity.run_id)
        .await
        .expect("load agent turn run")
        .expect("OpenRouter run is durable");
    assert_eq!(run.requested_runtime, "openrouter");
    assert_eq!(run.actual_runtime.as_deref(), Some("openrouter"));
    assert_eq!(run.status, AgentTurnRunStatus::Running);
    assert!(
        executor_db
            .codex_run(&identity.run_id)
            .await
            .expect("load Codex run")
            .is_none()
    );

    for _ in 0..4 {
        drive(controller_db, "observe OpenRouter durable start").await;
        if assignment(controller_db, &execution_id)
            .await
            .started_at
            .is_some()
        {
            break;
        }
    }
    assert!(
        assignment(controller_db, &execution_id)
            .await
            .started_at
            .is_some(),
        "controller never retained the verified durable start observation"
    );
    assert_openrouter_ticket_runtime(controller_db, &execution_id).await;
    assert_eq!(
        executor_db
            .reconcile_interrupted_agent_turn_runs()
            .await
            .expect("preserve correlated OpenRouter run"),
        0
    );
    drop(seam);
    reconcile_executor_tick(&executor, "settle restart-evicted OpenRouter run").await;
    let run_count: i64 = query_scalar("SELECT COUNT(*) FROM agent_turn_runs WHERE run_id = ?1")
        .bind(&identity.run_id)
        .fetch_one(executor_db.pool())
        .await
        .expect("count exactly one durable OpenRouter run");
    assert_eq!(run_count, 1);
    let second_assignment = wait_for_retry_assignment(
        &controller,
        &executor,
        controller_db,
        &execution_id,
        &claimed,
    )
    .await;
    let retry_seam = install_deterministic_runtime_seam().await;
    reconcile_executor_tick(&executor, "acquire retried OpenRouter start authority").await;
    reconcile_executor_tick(&executor, "start retried durable OpenRouter turn").await;
    let second_executor_record =
        executor_assignment(executor_db, &second_assignment.assignment_id).await;
    let second_identity = crate::daemon::db::remote_executor_identity(&second_executor_record)
        .expect("retried OpenRouter executor identity");
    assert_ne!(second_identity.run_id, identity.run_id);
    assert_eq!(retry_seam.start_count().await, 1);
    assert_eq!(
        query_scalar::<_, i64>("SELECT COUNT(*) FROM agent_turn_runs")
            .fetch_one(executor_db.pool())
            .await
            .expect("count durable OpenRouter attempts"),
        2
    );
    assert!(
        executor_db
            .codex_run(&second_identity.run_id)
            .await
            .expect("load retried Codex run")
            .is_none()
    );
    for _ in 0..4 {
        drive(controller_db, "observe retried OpenRouter durable start").await;
        if assignment(controller_db, &execution_id)
            .await
            .started_at
            .is_some()
        {
            break;
        }
    }
    assert!(
        assignment(controller_db, &execution_id)
            .await
            .started_at
            .is_some(),
        "controller never retained the retried durable start observation"
    );
    let reopened = AsyncDaemonDb::connect(&fixture.controller_path)
        .await
        .expect("reopen originating controller database");
    assert_openrouter_ticket_runtime(&reopened, &execution_id).await;
    server.stop().await;
}

async fn select_openrouter_reviewer(db: &AsyncDaemonDb) {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load controller settings");
    let reviewer = settings
        .reviewers
        .profiles
        .first_mut()
        .expect("default reviewer");
    reviewer.runtime = "openrouter".into();
    reviewer.model = Some("deepseek/deepseek-v4-flash".into());
    settings.retry.base_delay_seconds = 0;
    settings.retry.deterministic_jitter_percent = 0;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("select OpenRouter reviewer");
}

async fn wait_for_retry_assignment(
    controller: &crate::daemon::http::DaemonHttpState,
    executor: &crate::daemon::http::DaemonHttpState,
    db: &AsyncDaemonDb,
    execution_id: &str,
    first: &crate::daemon::db::TaskBoardRemoteAssignmentRecord,
) -> crate::daemon::db::TaskBoardRemoteAssignmentRecord {
    let mut last_execution = None;
    for _ in 0..12 {
        reconcile_executor_tick(executor, "advance interrupted OpenRouter cleanup").await;
        drive(db, "adopt restart failure and retry OpenRouter review").await;
        let before_local = db
            .task_board_workflow_execution(execution_id)
            .await
            .expect("load retrying OpenRouter execution")
            .expect("retrying OpenRouter execution exists");
        if before_local.transition.execution_state
            != crate::task_board::TaskBoardExecutionState::Preparing
            && crate::task_board::task_board_remote_execution_target(&before_local).is_none()
        {
            crate::daemon::task_board_read_only_coordinator::reconcile_task_board_read_only_workflows(
                controller, db,
            )
            .await
            .expect("advance retry through the production board coordinator");
        }
        let execution = db
            .task_board_workflow_execution(execution_id)
            .await
            .expect("reload retrying OpenRouter execution")
            .expect("retrying OpenRouter execution still exists");
        last_execution = Some(execution.clone());
        let Some(assignment_id) = crate::task_board::task_board_remote_execution_target(&execution)
        else {
            continue;
        };
        if assignment_id == first.assignment_id {
            continue;
        }
        let retried = db
            .task_board_remote_assignment(assignment_id)
            .await
            .expect("load retried OpenRouter assignment")
            .expect("retried OpenRouter assignment exists");
        if retried.state == crate::task_board::TaskBoardRemoteAssignmentState::Claimed {
            assert_eq!(execution.attempts.len(), 2);
            assert_eq!(
                retried
                    .require_offer()
                    .expect("retried sealed offer")
                    .launch
                    .runtime,
                "openrouter"
            );
            return retried;
        }
    }
    panic!("controller never claimed a fresh OpenRouter retry assignment: {last_execution:#?}")
}

async fn assert_openrouter_ticket_runtime(db: &AsyncDaemonDb, execution_id: &str) {
    let execution = db
        .task_board_workflow_execution(execution_id)
        .await
        .expect("load OpenRouter execution")
        .expect("OpenRouter execution exists");
    let report = crate::daemon::service::get_task_board_ai_review_report_db(
        db,
        &TaskBoardGetItemRequest {
            id: execution.item_id,
        },
    )
    .await
    .expect("load originating ticket report");
    assert!(
        matches!(
            &report,
            TaskBoardAiReviewReportResponse::Running {
                runtime,
                requested_runtime,
                actual_runtime: Some(actual_runtime),
                ..
            } if runtime == "openrouter"
                && requested_runtime == "openrouter"
                && actual_runtime == "openrouter"
        ),
        "{report:?}"
    );
}
