//! Core daemon persistence: the `DaemonDb`/`AsyncDaemonDb` structs, schema
//! bootstrap, and migrations.
//!
//! Everything else - session, timeline, task-board, and remote-identity
//! queries - stays in `harness-daemon` as extension traits over these
//! structs, per issue #1231. This crate never depends back on
//! `harness-daemon`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use harness_kernel::errors::CliError;
use harness_protocol::session::SessionState;
use harness_session::index::DiscoveredProject;
use rusqlite::Connection;

use harness_daemon_snapshot as daemon_snapshot;

pub mod activity_fold_cache;
mod async_bootstrap;
mod async_pool;
pub mod audit_event_retention;
pub mod audit_event_retention_async;
mod core_types;
mod schema;
mod schema_migrations;
mod schema_sql;
mod task_board_sync_coordinator;
mod telemetry;

#[cfg(any(test, feature = "test-support"))]
pub use async_bootstrap::all_migration_versions;
pub use async_pool::AsyncDaemonDb;
pub use core_types::{DaemonDb, SCHEMA_VERSION};
pub use core_types::{
    LIVENESS_CANDIDATE_IDS_SQL, canonical_db_unavailable, db_error, i64_from_u64, u64_from_i64,
    usize_from_i64,
};
pub use schema::SchemaRepairHooks;
#[cfg(any(test, feature = "test-support"))]
pub use schema::set_schema_init_hook;
pub use task_board_sync_coordinator::{TaskBoardSyncPermit, TaskBoardSyncStatus};
pub use telemetry::{trace_async_db_operation, trace_sync_db_operation};
