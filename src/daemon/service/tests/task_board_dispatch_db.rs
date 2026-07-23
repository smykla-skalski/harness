use super::*;

use crate::daemon::db::{ReservedTaskBoardDispatch, approved_write_item};
use crate::daemon::protocol::SessionStartRequest;
use std::collections::HashMap;

use crate::task_board::{
    AgentMode, HARNESS_GITHUB_TOKEN_ENV, TaskBoardGitHubProjectConfig, TaskBoardItem,
    TaskBoardWorkflowKind, build_dispatch_plans_with_policy,
};

#[test]
fn prepared_dispatch_resumes_without_duplicate_session_or_task() {
    with_temp_project(|project| {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let db_path = project
                .parent()
                .expect("project parent")
                .join("dispatch.sqlite");
            let db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                .await
                .expect("open async daemon db");
            let mut settings = db
                .task_board_orchestrator_settings()
                .await
                .expect("load orchestrator settings");
            settings.github_project =
                TaskBoardGitHubProjectConfig::new("example", "compass", project.to_path_buf());
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
            let first_claim = db
                .claim_task_board_dispatch_preparation(&intent_id)
                .await
                .expect("claim preparation")
                .expect("pending preparation");

            let crate::task_board::SessionIntent::Create { title, context, .. } =
                &preparation.plan.session
            else {
                panic!("new task board item should create a session");
            };
            start_session_direct_async(
                &SessionStartRequest {
                    title: title.clone(),
                    context: context.clone().unwrap_or_else(|| title.clone()),
                    session_id: Some(preparation.session_id.clone()),
                    project_dir: project.to_string_lossy().into_owned(),
                    policy_preset: None,
                    base_ref: None,
                },
                &db,
            )
            .await
            .expect("create reserved session before simulated crash");
            assert!(
                db.delete_session_row(&preparation.session_id)
                    .await
                    .expect("remove database row for crash simulation")
            );
            assert!(
                db.resolve_session(&preparation.session_id)
                    .await
                    .expect("verify missing database row")
                    .is_none()
            );
            assert!(
                crate::session::storage::layout_from_project_dir(project, &preparation.session_id)
                    .expect("session layout")
                    .state_file()
                    .is_file(),
                "the crash fixture must retain file/worktree artifacts"
            );
            sqlx::query(
                "UPDATE task_board_dispatch_intents
                 SET claimed_at = '1970-01-01T00:00:00Z' WHERE intent_id = ?1",
            )
            .bind(&intent_id)
            .execute(db.pool())
            .await
            .expect("expire preparation claim");

            let reclaimed = db
                .claim_next_task_board_dispatch_preparation()
                .await
                .expect("reclaim preparation")
                .expect("expired preparation");
            assert_ne!(reclaimed.claim_token, first_claim.claim_token);
            let applied = temp_env::async_with_vars(
                [(HARNESS_GITHUB_TOKEN_ENV, Some("fixture-token"))],
                task_board::prepare_claimed_task_board_dispatch(&db, &reclaimed),
            )
            .await
            .expect("resume preparation");
            assert_eq!(applied.session_id, preparation.session_id);
            assert_eq!(applied.work_item_id, preparation.work_item_id);

            let resolved = db
                .resolve_session(&preparation.session_id)
                .await
                .expect("resolve session")
                .expect("session exists");
            assert_eq!(resolved.state.tasks.len(), 1);
            assert!(resolved.state.tasks.contains_key(&preparation.work_item_id));
            let linked = db
                .task_board_item("dispatch-crash-recovery")
                .await
                .expect("load linked item");
            assert_eq!(
                linked.session_id.as_deref(),
                Some(preparation.session_id.as_str())
            );
            assert_eq!(
                linked.work_item_id.as_deref(),
                Some(preparation.work_item_id.as_str())
            );
            assert_eq!(
                linked.workflow.branch.as_deref(),
                Some(resolved.state.branch_ref.as_str())
            );
            let canonical_worktree = std::fs::canonicalize(&resolved.state.worktree_path)
                .expect("canonical resolved worktree");
            assert_eq!(
                linked.workflow.worktree.as_deref(),
                canonical_worktree.to_str()
            );
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

            let (_, error) = task_board::prepare_claimed_task_board_dispatch(&db, &claim)
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
