use crate::session::types::SessionTransition;

use super::super::mutations_async::create_task_with_id_async;
use super::*;

const SESSION_ID: &str = "d87e3324-3234-5ab8-a4ad-4f630139e242";
const TASK_ID: &str = "task-board-reserved-retry";

#[test]
fn reserved_task_retry_repairs_file_mirror_and_notifies_without_duplicate_audit() {
    with_temp_project(|project| {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let db_path = project
                .parent()
                .expect("project parent")
                .join("daemon.sqlite");
            let async_db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
                .await
                .expect("open async daemon db");
            let state = start_direct_session_async(
                &async_db,
                project,
                SESSION_ID,
                "reserved task retry",
                "repair a stale file mirror",
                None,
            )
            .await;
            let request = TaskCreateRequest {
                actor: state.leader_id.expect("leader id"),
                title: "Repair durable dispatch".into(),
                context: Some("restore the task from canonical database state".into()),
                severity: crate::session::types::TaskSeverity::High,
                suggested_fix: Some("resynchronize the session mirror".into()),
            };

            create_task_with_id_async(SESSION_ID, TASK_ID, &request, &async_db)
                .await
                .expect("create reserved task");
            assert_eq!(task_created_audit_count(&async_db).await, 1);

            let layout = session_storage::layout_from_project_dir(project, SESSION_ID)
                .expect("session layout");
            session_storage::update_state(&layout, |mirror| {
                assert!(
                    mirror.tasks.remove(TASK_ID).is_some(),
                    "task must exist before simulating a stale mirror"
                );
                Ok(())
            })
            .expect("remove task from file mirror");
            assert!(
                !load_mirror(&layout).tasks.contains_key(TASK_ID),
                "test setup must remove only the mirrored task"
            );
            assert!(
                async_db
                    .resolve_session(SESSION_ID)
                    .await
                    .expect("resolve canonical session")
                    .expect("canonical session exists")
                    .state
                    .tasks
                    .contains_key(TASK_ID),
                "canonical database task must remain present"
            );

            let revision_before_retry = async_db
                .current_change_sequence()
                .await
                .expect("change sequence before retry");
            create_task_with_id_async(SESSION_ID, TASK_ID, &request, &async_db)
                .await
                .expect("retry reserved task creation");

            let repaired = load_mirror(&layout);
            let task = repaired.tasks.get(TASK_ID).expect("repaired mirrored task");
            assert_eq!(task.title, request.title);
            assert_eq!(task.context, request.context);

            let revision_after_retry = async_db
                .current_change_sequence()
                .await
                .expect("change sequence after retry");
            assert!(revision_after_retry > revision_before_retry);
            let changes = async_db
                .load_change_tracking_since(revision_before_retry)
                .await
                .expect("retry change tracking");
            let session_scope = format!("session:{SESSION_ID}");
            assert!(changes.iter().any(|(scope, _)| scope == &session_scope));
            assert!(changes.iter().any(|(scope, _)| scope == "global"));
            assert_eq!(task_created_audit_count(&async_db).await, 1);
        });
    });
}

fn load_mirror(
    layout: &crate::workspace::layout::SessionLayout,
) -> crate::session::types::SessionState {
    session_storage::load_state(layout)
        .expect("load file mirror")
        .expect("file mirror exists")
}

async fn task_created_audit_count(async_db: &crate::daemon::db::AsyncDaemonDb) -> usize {
    sqlx::query_scalar::<_, String>(
        "SELECT transition_json FROM session_log WHERE session_id = ?1 ORDER BY sequence",
    )
    .bind(SESSION_ID)
    .fetch_all(async_db.pool())
    .await
    .expect("load session audit log")
    .into_iter()
    .map(|json| serde_json::from_str::<SessionTransition>(&json).expect("decode audit transition"))
    .filter(|transition| {
        matches!(
            transition,
            SessionTransition::TaskCreated { task_id, .. } if task_id == TASK_ID
        )
    })
    .count()
}
