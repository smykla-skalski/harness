use std::path::Path;

use sqlx::{query, query_as};
use uuid::Uuid;

use super::imports::TaskBoardImportMarker;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};

impl AsyncDaemonDb {
    pub(crate) async fn task_board_instance_id(&self) -> Result<String, CliError> {
        let candidate = format!("task-board-{}", Uuid::new_v4().simple());
        query("INSERT OR IGNORE INTO task_board_identity (singleton, instance_id) VALUES (1, ?1)")
            .bind(candidate)
            .execute(self.pool())
            .await
            .map_err(|error| {
                db_error(format!("initialize Task Board instance identity: {error}"))
            })?;
        query_as::<_, (String,)>("SELECT instance_id FROM task_board_identity WHERE singleton = 1")
            .fetch_one(self.pool())
            .await
            .map(|row| row.0)
            .map_err(|error| db_error(format!("load Task Board instance identity: {error}")))
    }

    pub(crate) async fn task_board_import_marker(
        &self,
        source_kind: &str,
    ) -> Result<Option<TaskBoardImportMarker>, CliError> {
        query_as::<_, TaskBoardImportMarker>(
            "SELECT * FROM task_board_imports WHERE source_kind = ?1",
        )
        .bind(source_kind)
        .fetch_optional(self.pool())
        .await
        .map_err(|error| db_error(format!("load task board import marker: {error}")))
    }

    pub(crate) async fn task_board_revision(&self) -> Result<i64, CliError> {
        query_as::<_, (i64,)>(
            "SELECT COALESCE(MAX(change_seq), 0) FROM change_tracking
             WHERE scope LIKE 'task_board:%'",
        )
        .fetch_one(self.pool())
        .await
        .map(|row| row.0)
        .map_err(|error| db_error(format!("load task board revision: {error}")))
    }

    pub(crate) async fn pending_task_board_secret_handoff(
        &self,
    ) -> Result<Option<TaskBoardImportMarker>, CliError> {
        query_as::<_, TaskBoardImportMarker>(
            "SELECT * FROM task_board_imports WHERE secret_handoff_phase != 'complete'
             ORDER BY imported_at LIMIT 1",
        )
        .fetch_optional(self.pool())
        .await
        .map_err(|error| db_error(format!("load pending Task Board secret handoff: {error}")))
    }

    pub(crate) async fn completed_task_board_secret_handoff(
        &self,
    ) -> Result<Option<TaskBoardImportMarker>, CliError> {
        query_as::<_, TaskBoardImportMarker>(
            "SELECT * FROM task_board_imports WHERE secret_handoff_phase = 'complete'
             AND secret_handoff_digest IS NOT NULL ORDER BY imported_at LIMIT 1",
        )
        .fetch_optional(self.pool())
        .await
        .map_err(|error| db_error(format!("load completed Task Board secret handoff: {error}")))
    }

    pub(crate) async fn task_board_secret_handoff(
        &self,
        migration_id: &str,
    ) -> Result<Option<TaskBoardImportMarker>, CliError> {
        query_as::<_, TaskBoardImportMarker>(
            "SELECT * FROM task_board_imports WHERE secret_handoff_id = ?1",
        )
        .bind(migration_id)
        .fetch_optional(self.pool())
        .await
        .map_err(|error| db_error(format!("load Task Board secret handoff: {error}")))
    }

    pub(crate) async fn acknowledge_task_board_secret_handoff(
        &self,
        migration_id: &str,
        digest: &str,
    ) -> Result<(), CliError> {
        let result = query(
            "UPDATE task_board_imports
             SET secret_handoff_phase = 'acknowledging', secret_acknowledged_at = ?3
             WHERE secret_handoff_id = ?1 AND secret_handoff_digest = ?2
               AND secret_handoff_phase IN ('pending', 'acknowledging')",
        )
        .bind(migration_id)
        .bind(digest)
        .bind(utc_now())
        .execute(self.pool())
        .await
        .map_err(|error| db_error(format!("acknowledge Task Board secret handoff: {error}")))?;
        if result.rows_affected() != 1 {
            return Err(db_error(
                "Task Board secret handoff acknowledgement is stale",
            ));
        }
        Ok(())
    }

    pub(crate) async fn complete_task_board_secret_handoff(
        &self,
        migration_id: &str,
    ) -> Result<(), CliError> {
        let result = query(
            "UPDATE task_board_imports SET secret_handoff_phase = 'complete'
             WHERE secret_handoff_id = ?1 AND secret_handoff_phase = 'acknowledging'",
        )
        .bind(migration_id)
        .execute(self.pool())
        .await
        .map_err(|error| db_error(format!("complete Task Board secret handoff: {error}")))?;
        if result.rows_affected() != 1 {
            return Err(db_error(
                "Task Board secret handoff is not awaiting cleanup",
            ));
        }
        Ok(())
    }

    pub(crate) async fn mark_task_board_archive_complete(
        &self,
        source_kind: &str,
        archive_path: &Path,
        archived_at: &str,
    ) -> Result<(), CliError> {
        query(
            "UPDATE task_board_imports SET archived_at = ?2, archive_path = ?3
             WHERE source_kind = ?1",
        )
        .bind(source_kind)
        .bind(archived_at)
        .bind(archive_path.to_string_lossy().into_owned())
        .execute(self.pool())
        .await
        .map_err(|error| db_error(format!("finalize task board archive: {error}")))?;
        Ok(())
    }
}
