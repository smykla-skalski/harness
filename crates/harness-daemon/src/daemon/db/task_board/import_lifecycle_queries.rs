//! Import-lifecycle's own interface onto [`AsyncDaemonDb`], scoped to the
//! one-time legacy snapshot import, instance-identity bootstrap, and
//! secret-handoff bookkeeping the daemon runs during migration and startup.
//!
//! `task_board` doesn't own `AsyncDaemonDb` -- it's a sibling module's type --
//! so an inherent `impl AsyncDaemonDb` block for import-lifecycle queries can
//! never move into a crate `task_board` doesn't share with `db`. A trait
//! `task_board` itself declares has no such problem: Rust's orphan rule only
//! requires one of the trait or the implementing type to be local, and the
//! trait is. That is what lets this one area's queries move into their own
//! crate later without dragging every other area's inherent impls along for
//! the ride.
//!
//! `AsyncDaemonDb` keeps its original inherent methods too, each now a thin
//! forward into the matching trait method, so nothing outside `db/task_board`
//! has to change to keep calling them by the same name.

use std::path::Path;

use super::imports::{TaskBoardImportMarker, TaskBoardImportResult};
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::TaskBoardGitRuntimeConfig;
use crate::task_board::legacy_import::LegacyTaskBoardSnapshot;

pub(crate) trait ImportLifecycleQueries: Send + Sync {
    /// This instance's stable identity, minted the first time it is read.
    ///
    /// # Errors
    /// Returns [`CliError`] when the identity cannot be read or written.
    async fn task_board_instance_id(&self) -> Result<String, CliError>;

    /// The import marker for `source_kind`, if that source has ever been
    /// imported.
    ///
    /// # Errors
    /// Returns [`CliError`] when the marker cannot be read.
    async fn task_board_import_marker(
        &self,
        source_kind: &str,
    ) -> Result<Option<TaskBoardImportMarker>, CliError>;

    /// The highest change-tracking sequence across every task-board scope.
    ///
    /// # Errors
    /// Returns [`CliError`] when the revision cannot be read.
    async fn task_board_revision(&self) -> Result<i64, CliError>;

    /// The oldest import marker still awaiting its secret handoff.
    ///
    /// # Errors
    /// Returns [`CliError`] when the marker cannot be read.
    async fn pending_task_board_secret_handoff(
        &self,
    ) -> Result<Option<TaskBoardImportMarker>, CliError>;

    /// The oldest import marker whose secret handoff has completed.
    ///
    /// # Errors
    /// Returns [`CliError`] when the marker cannot be read.
    async fn completed_task_board_secret_handoff(
        &self,
    ) -> Result<Option<TaskBoardImportMarker>, CliError>;

    /// The import marker carrying `migration_id`'s secret handoff.
    ///
    /// # Errors
    /// Returns [`CliError`] when the marker cannot be read.
    async fn task_board_secret_handoff(
        &self,
        migration_id: &str,
    ) -> Result<Option<TaskBoardImportMarker>, CliError>;

    /// Move a pending secret handoff into `acknowledging`, CAS'd against the
    /// digest the caller expects to be acknowledging.
    ///
    /// # Errors
    /// Returns [`CliError`] when no matching row is pending acknowledgement.
    async fn acknowledge_task_board_secret_handoff(
        &self,
        migration_id: &str,
        digest: &str,
    ) -> Result<(), CliError>;

    /// Move an acknowledging secret handoff into `complete`.
    ///
    /// # Errors
    /// Returns [`CliError`] when no matching row is awaiting cleanup.
    async fn complete_task_board_secret_handoff(&self, migration_id: &str) -> Result<(), CliError>;

    /// Record that the archive for `source_kind` has been written to
    /// `archive_path`.
    ///
    /// # Errors
    /// Returns [`CliError`] when the marker cannot be written.
    async fn mark_task_board_archive_complete(
        &self,
        source_kind: &str,
        archive_path: &Path,
        archived_at: &str,
    ) -> Result<(), CliError>;

    /// Import a legacy global task board snapshot exactly once. A second call
    /// with the same source digest is a no-op that reports the state the
    /// first import left; a changed digest is an error.
    ///
    /// # Errors
    /// Returns [`CliError`] when the snapshot conflicts with a prior import,
    /// the target tables are not empty, or the import cannot be written.
    async fn import_legacy_task_board(
        &self,
        snapshot: &LegacyTaskBoardSnapshot,
        staged_path: Option<&Path>,
        runtime_config: &TaskBoardGitRuntimeConfig,
        secret_handoff_digest: Option<&str>,
    ) -> Result<TaskBoardImportResult, CliError>;

    /// Seed a fresh database as if an empty legacy snapshot had been
    /// imported, so every daemon instance passes through the same import
    /// bookkeeping regardless of whether it has real legacy state to bring
    /// in.
    ///
    /// # Errors
    /// Returns [`CliError`] when the import cannot be written.
    async fn initialize_empty_task_board(
        &self,
        runtime_config: &TaskBoardGitRuntimeConfig,
        secret_handoff_digest: Option<&str>,
    ) -> Result<TaskBoardImportResult, CliError>;
}

/// The trait's one and only impl for [`AsyncDaemonDb`]. Every method is a
/// thin, single-line forward into the free function that actually owns the
/// area's query logic, kept in the file the query has always lived in
/// (`import_lifecycle.rs`, `imports.rs`) so this file stays a pure interface
/// plus wiring, not a dumping ground.
impl ImportLifecycleQueries for AsyncDaemonDb {
    async fn task_board_instance_id(&self) -> Result<String, CliError> {
        super::import_lifecycle::task_board_instance_id(self).await
    }

    async fn task_board_import_marker(
        &self,
        source_kind: &str,
    ) -> Result<Option<TaskBoardImportMarker>, CliError> {
        super::import_lifecycle::task_board_import_marker(self, source_kind).await
    }

    async fn task_board_revision(&self) -> Result<i64, CliError> {
        super::import_lifecycle::task_board_revision(self).await
    }

    async fn pending_task_board_secret_handoff(
        &self,
    ) -> Result<Option<TaskBoardImportMarker>, CliError> {
        super::import_lifecycle::pending_task_board_secret_handoff(self).await
    }

    async fn completed_task_board_secret_handoff(
        &self,
    ) -> Result<Option<TaskBoardImportMarker>, CliError> {
        super::import_lifecycle::completed_task_board_secret_handoff(self).await
    }

    async fn task_board_secret_handoff(
        &self,
        migration_id: &str,
    ) -> Result<Option<TaskBoardImportMarker>, CliError> {
        super::import_lifecycle::task_board_secret_handoff(self, migration_id).await
    }

    async fn acknowledge_task_board_secret_handoff(
        &self,
        migration_id: &str,
        digest: &str,
    ) -> Result<(), CliError> {
        super::import_lifecycle::acknowledge_task_board_secret_handoff(self, migration_id, digest)
            .await
    }

    async fn complete_task_board_secret_handoff(&self, migration_id: &str) -> Result<(), CliError> {
        super::import_lifecycle::complete_task_board_secret_handoff(self, migration_id).await
    }

    async fn mark_task_board_archive_complete(
        &self,
        source_kind: &str,
        archive_path: &Path,
        archived_at: &str,
    ) -> Result<(), CliError> {
        super::import_lifecycle::mark_task_board_archive_complete(
            self,
            source_kind,
            archive_path,
            archived_at,
        )
        .await
    }

    async fn import_legacy_task_board(
        &self,
        snapshot: &LegacyTaskBoardSnapshot,
        staged_path: Option<&Path>,
        runtime_config: &TaskBoardGitRuntimeConfig,
        secret_handoff_digest: Option<&str>,
    ) -> Result<TaskBoardImportResult, CliError> {
        super::imports::import_legacy_task_board(
            self,
            snapshot,
            staged_path,
            runtime_config,
            secret_handoff_digest,
        )
        .await
    }

    async fn initialize_empty_task_board(
        &self,
        runtime_config: &TaskBoardGitRuntimeConfig,
        secret_handoff_digest: Option<&str>,
    ) -> Result<TaskBoardImportResult, CliError> {
        super::imports::initialize_empty_task_board(self, runtime_config, secret_handoff_digest)
            .await
    }
}
