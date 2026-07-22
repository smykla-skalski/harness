use super::super::completion_evidence_tests::remote_offer;
use super::super::remote_start_tests::PreparedRemoteOffer;
use crate::daemon::task_board_remote_transport::wire::RemoteSourceMaterial;
use crate::task_board::{TaskBoardExecutionPhase, TaskBoardWorkflowKind};

pub(crate) async fn prepare_remote_implementation_offer(
    label: &str,
    worktree: &str,
    base_head_revision: &str,
) -> PreparedRemoteOffer {
    let (db, intent, preparation, launch) =
        super::super::write_workflow_tests::reserved_write_at(
            label,
            Some("example/harness"),
            worktree,
            base_head_revision,
            true,
        )
        .await;
    let applied =
        super::super::write_workflow_tests::publish_write(&db, &preparation, launch).await;
    let execution_id = applied
        .item
        .workflow
        .execution_id
        .clone()
        .expect("implementation execution id");
    let claim = db
        .claim_task_board_dispatch(&applied.board_item_id)
        .await
        .expect("claim implementation dispatch")
        .expect("pending implementation dispatch");
    db.prepare_task_board_workflow_dispatch(&intent, &claim.claim_token)
        .await
        .expect("prepare implementation workflow");
    normalize_prepared_times(&db, &execution_id).await;
    let execution = db
        .task_board_workflow_execution(&execution_id)
        .await
        .expect("load implementation execution")
        .expect("implementation execution");
    let attempt = execution.attempts[0].clone();
    let mut offer = remote_offer(&execution, &attempt);
    offer.binding.phase = TaskBoardExecutionPhase::Implementation;
    offer.binding.workflow_kind = TaskBoardWorkflowKind::DefaultTask;
    offer.binding.base_revision = base_head_revision.into();
    offer.binding.expected_head_revision = None;
    offer.source =
        RemoteSourceMaterial::repository_revision("example/harness", base_head_revision);
    offer = offer.seal().expect("seal implementation offer");
    PreparedRemoteOffer {
        db,
        intent,
        execution_id,
        execution,
        attempt,
        offer,
    }
}

async fn normalize_prepared_times(
    db: &crate::daemon::db::AsyncDaemonDb,
    execution_id: &str,
) {
    sqlx::query(
        "UPDATE task_board_workflow_executions
         SET created_at = '2026-07-19T10:00:00Z', updated_at = '2026-07-19T10:00:00Z'
         WHERE execution_id = ?1",
    )
    .bind(execution_id)
    .execute(db.pool())
    .await
    .expect("normalize implementation execution time");
    sqlx::query(
        "UPDATE task_board_execution_attempts
         SET started_at = '2026-07-19T10:00:00Z', updated_at = '2026-07-19T10:00:00Z'
         WHERE execution_id = ?1",
    )
    .bind(execution_id)
    .execute(db.pool())
    .await
    .expect("normalize implementation attempt time");
}
