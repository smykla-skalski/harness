use super::*;

use crate::daemon::db::{ReservedTaskBoardDispatch, approved_write_item};
use harness_daemon_db_queries::AsyncAgentWorkingCopyQueries;
use std::collections::HashMap;

use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::db_open::AsyncDaemonDbConnect;
use crate::task_board::{
    AgentMode, HARNESS_GITHUB_TOKEN_ENV, TaskBoardGitHubProjectConfig, TaskBoardItem,
    TaskBoardWorkflowKind, build_dispatch_plans_with_policy,
};

struct CrashedDispatchPreparation {
    db: crate::daemon::db_handle::AsyncDaemonDbHandle,
    first_claim_token: String,
    working_copy_id: String,
    work_item_id: String,
}

async fn dispatch_resume_prepare_and_simulate_crash(
    project: &std::path::Path,
) -> CrashedDispatchPreparation {
    let db_path = project
        .parent()
        .expect("project parent")
        .join("dispatch.sqlite");
    let db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db");
    let db = AsyncDaemonDbHandle(db);
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load orchestrator settings");
    settings.github_project = TaskBoardGitHubProjectConfig::default();
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure write publication");
    let mut item = approved_write_item(TaskBoardItem::new(
        "dispatch-crash-recovery".to_string(),
        "Recover dispatch".to_string(),
        "Create the worker task once".to_string(),
        "2026-07-11T10:00:00Z".to_string(),
    ));
    item.execution_repository = Some("example/compass".into());
    db.create_task_board_item(item)
        .await
        .expect("create task board item");
    let item = db
        .task_board_item("dispatch-crash-recovery")
        .await
        .expect("load task board item");
    let plan = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        crate::task_board::SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0);
    let reserved = db
        .reserve_task_board_dispatch(
            &plan,
            crate::session::types::CONTROL_PLANE_ACTOR_ID,
            Some(project.to_string_lossy().as_ref()),
            false,
        )
        .await
        .expect("reserve dispatch");
    let (intent_id, preparation) = match reserved {
        ReservedTaskBoardDispatch::Preparing {
            intent_id,
            preparation,
        } => (intent_id, preparation),
        ReservedTaskBoardDispatch::Applied(_) => panic!("new dispatch already applied"),
        ReservedTaskBoardDispatch::Blocked(_) => {
            panic!("default admission blocked dispatch")
        }
    };
    assert!(
        preparation.session_id.is_none(),
        "a fresh dispatch reserves no Session"
    );
    let working_copy_id = preparation
        .working_copy_id
        .clone()
        .expect("fresh dispatch reserves a working copy");
    let first_claim = db
        .claim_task_board_dispatch_preparation(&intent_id)
        .await
        .expect("claim preparation")
        .expect("pending preparation");

    // Crash the holder mid-preparation by expiring its claim; the reclaim below
    // must resume onto the same reserved working copy rather than mint another.
    sqlx::query(
        "UPDATE task_board_dispatch_intents
         SET claimed_at = '1970-01-01T00:00:00Z' WHERE intent_id = ?1",
    )
    .bind(&intent_id)
    .execute(db.pool())
    .await
    .expect("expire preparation claim");

    CrashedDispatchPreparation {
        db,
        first_claim_token: first_claim.claim_token,
        working_copy_id,
        work_item_id: preparation.work_item_id,
    }
}

async fn dispatch_resume_reclaim_and_assert(crashed: CrashedDispatchPreparation) {
    let db = crashed.db;
    let reclaimed = db
        .claim_next_task_board_dispatch_preparation()
        .await
        .expect("reclaim preparation")
        .expect("expired preparation");
    assert_ne!(reclaimed.claim_token, crashed.first_claim_token);
    let applied = Box::pin(temp_env::async_with_vars(
        [(HARNESS_GITHUB_TOKEN_ENV, Some("fixture-token"))],
        task_board::prepare_claimed_task_board_dispatch(&db, &reclaimed),
    ))
    .await
    .expect("resume preparation");

    assert_eq!(applied.session_id, None);
    assert_eq!(
        applied.working_copy_id.as_deref(),
        Some(crashed.working_copy_id.as_str()),
        "the resumed preparation must reuse the reserved working copy"
    );
    let workspace_id = applied
        .workspace_id
        .clone()
        .expect("a started dispatch belongs to a workspace");
    assert_eq!(applied.work_item_id, crashed.work_item_id);

    let sessions = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM sessions")
        .fetch_one(db.pool())
        .await
        .expect("count sessions");
    assert_eq!(sessions, 0, "starting a worker must create no Session row");
    let tasks = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM tasks")
        .fetch_one(db.pool())
        .await
        .expect("count session tasks");
    assert_eq!(tasks, 0, "starting a worker must create no Session task");

    let linked = db
        .task_board_item("dispatch-crash-recovery")
        .await
        .expect("load linked item");
    assert_eq!(linked.session_id, None);
    assert_eq!(linked.workspace_id.as_deref(), Some(workspace_id.as_str()));
    assert_eq!(
        linked.working_copy_id.as_deref(),
        Some(crashed.working_copy_id.as_str())
    );
    assert_eq!(
        linked.work_item_id.as_deref(),
        Some(crashed.work_item_id.as_str())
    );

    let recorded = db
        .load_agent_working_copy(&crashed.working_copy_id)
        .await
        .expect("load recorded working copy")
        .expect("the dispatch recorded its checkout");
    assert_eq!(recorded.workspace_id, workspace_id);
    assert!(!recorded.released);
    assert_eq!(
        linked.workflow.worktree.as_deref(),
        Some(recorded.worktree_path.as_str()),
        "the ticket must point at the checkout the daemon actually made"
    );
    assert_eq!(
        linked.workflow.branch.as_deref(),
        Some(recorded.branch_ref.as_str())
    );
    assert!(
        std::path::Path::new(&recorded.worktree_path).is_dir(),
        "the recorded checkout must exist on disk"
    );
}

#[test]
fn prepared_dispatch_resumes_onto_one_workspace_and_no_session() {
    with_temp_project(|project| {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let crashed = dispatch_resume_prepare_and_simulate_crash(project).await;
            dispatch_resume_reclaim_and_assert(crashed).await;
        });
    });
}

#[test]
fn read_only_dispatch_rejects_aba_after_claim_before_late_head_resolution() {
    with_temp_project(|project| {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let db = crate::daemon::db::AsyncDaemonDb::connect(
                &project
                    .parent()
                    .expect("project parent")
                    .join("read-only.sqlite"),
            )
            .await
            .expect("open async daemon db");
            let db = AsyncDaemonDbHandle(db);
            let mut item = TaskBoardItem::new(
                "dispatch-read-only-aba".into(),
                "Review exact head".into(),
                "Review without workspace writes".into(),
                "2026-07-18T10:00:00Z".into(),
            );
            item.agent_mode = AgentMode::Evaluate;
            item.workflow_kind = TaskBoardWorkflowKind::Review;
            db.create_task_board_item(item.clone())
                .await
                .expect("create read-only item");
            let plan = build_dispatch_plans_with_policy(
                &[item],
                None,
                None,
                crate::task_board::SpawnGateSwitches::default(),
                &HashMap::new(),
            )
            .remove(0);
            let reserved = db
                .reserve_task_board_dispatch(
                    &plan,
                    crate::session::types::CONTROL_PLANE_ACTOR_ID,
                    Some(project.to_string_lossy().as_ref()),
                    false,
                )
                .await
                .expect("reserve read-only dispatch");
            let intent_id = match reserved {
                ReservedTaskBoardDispatch::Preparing {
                    intent_id,
                    preparation,
                } => {
                    assert!(preparation.source_item_revision.is_some());
                    intent_id
                }
                other => panic!("unexpected reservation: {other:?}"),
            };
            let claim = db
                .claim_task_board_dispatch_preparation(&intent_id)
                .await
                .expect("claim read-only preparation")
                .expect("pending read-only preparation");
            for title in ["Transient edit", "Review exact head"] {
                db.update_task_board_item(&plan.board_item_id, |item| {
                    item.title = title.into();
                    Ok(true)
                })
                .await
                .expect("mutate item during preparation")
                .expect("item mutation");
            }

            let (_, error) = Box::pin(task_board::prepare_claimed_task_board_dispatch(&db, &claim))
                .await
                .expect_err("late production capture must reject revision ABA");

            assert!(
                error
                    .to_string()
                    .contains("changed after dispatch reservation")
            );
            let status: String = sqlx::query_scalar(
                "SELECT status FROM task_board_dispatch_intents WHERE intent_id = ?1",
            )
            .bind(&intent_id)
            .fetch_one(db.pool())
            .await
            .expect("load intent status");
            assert_eq!(status, "preparing_claimed");
        });
    });
}
