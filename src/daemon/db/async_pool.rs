use std::time::Duration;

use sqlx::pool::PoolOptions;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqliteSynchronous};
use sqlx::{Sqlite, SqlitePool, query_as};

use super::{
    BTreeMap, CliError, DiscoveredProject, Path, PathBuf, SCHEMA_VERSION, SessionState,
    async_bootstrap, daemon_index, daemon_protocol, db_error, trace_async_db_operation,
    usize_from_i64,
};
use crate::session::service::canonicalize_active_session_without_leader;
use crate::telemetry::{record_daemon_db_health_counts, record_daemon_db_pool_state};
use crate::workspace::utc_now;

const ASYNC_DB_ACQUIRE_TIMEOUT: Duration = Duration::from_secs(5);
const ASYNC_DB_BUSY_TIMEOUT: Duration = Duration::from_secs(5);
const ASYNC_DB_MAX_CONNECTIONS: u32 = 8;
const HEALTH_COUNTS_SQL: &str = "SELECT
    COUNT(DISTINCT COALESCE(NULLIF(p.repository_root, ''), p.project_dir, p.project_id)) AS project_count,
    COUNT(DISTINCT CASE WHEN p.is_worktree = 1 THEN p.checkout_id END) AS worktree_count,
    COUNT(DISTINCT s.session_id) AS session_count
  FROM sessions s
  JOIN projects p ON p.project_id = s.project_id";
const PROJECT_SUMMARIES_SQL: &str = "SELECT
    p.project_id,
    p.name,
    p.project_dir,
    p.repository_root,
    p.context_root,
    p.checkout_id,
    p.checkout_name,
    p.is_worktree,
    p.worktree_name,
    COUNT(CASE WHEN s.is_active = 1 THEN 1 END) AS active_session_count,
    COUNT(s.session_id) AS total_session_count
 FROM projects p
 LEFT JOIN sessions s ON s.project_id = p.project_id
 GROUP BY p.project_id, p.checkout_id
 ORDER BY p.name, p.checkout_name";
const SESSION_SUMMARIES_SQL: &str = "SELECT
    s.session_id,
    s.title,
    s.context,
    s.status,
    s.created_at,
    s.updated_at,
    s.last_activity_at,
    s.leader_id,
    s.observe_id,
    s.pending_leader_transfer AS pending_leader_transfer_json,
    s.metrics_json,
    s.state_json,
    p.project_id,
    p.name AS project_name,
    p.project_dir,
    p.repository_root,
    p.context_root,
    p.checkout_id,
    p.checkout_name,
    p.is_worktree,
    p.worktree_name
 FROM sessions s
 JOIN projects p ON p.project_id = s.project_id
 ORDER BY s.updated_at DESC";
const RESOLVE_SESSION_SQL: &str = "SELECT
    s.state_json,
    p.project_id,
    p.name AS project_name,
    p.project_dir,
    p.repository_root,
    p.checkout_id,
    p.checkout_name,
    p.context_root,
    p.is_worktree,
    p.worktree_name
 FROM sessions s
 JOIN projects p ON p.project_id = s.project_id
 WHERE s.session_id = ?1";

/// Async `SQLx` pool over the canonical daemon `SQLite` database.
#[derive(Debug)]
pub(crate) struct AsyncDaemonDb {
    pool: SqlitePool,
    pub(super) path: PathBuf,
}

impl AsyncDaemonDb {
    /// Open the canonical daemon `SQLite` database through `SQLx`.
    ///
    /// # Errors
    /// Returns [`CliError`] when the pool or schema probe cannot be initialized.
    pub(crate) async fn connect(path: &Path) -> Result<Self, CliError> {
        trace_async_db_operation("connect", "maintenance", Some(path), || async move {
            async_bootstrap::prepare_legacy_schema(path)?;
            let options = SqliteConnectOptions::new()
                .filename(path)
                .create_if_missing(true)
                .foreign_keys(true)
                .journal_mode(SqliteJournalMode::Wal)
                .synchronous(SqliteSynchronous::Normal)
                .busy_timeout(ASYNC_DB_BUSY_TIMEOUT)
                .pragma("cache_size", "-8000");

            let pool = PoolOptions::<Sqlite>::new()
                .max_connections(ASYNC_DB_MAX_CONNECTIONS)
                .min_connections(1)
                .acquire_timeout(ASYNC_DB_ACQUIRE_TIMEOUT)
                .connect_with(options)
                .await
                .map_err(|error| db_error(format!("open async daemon database pool: {error}")))?;

            let db = Self {
                pool,
                path: path.to_path_buf(),
            };
            async_bootstrap::ensure_async_schema(db.pool()).await?;
            let version = db.schema_version().await?;
            if version != SCHEMA_VERSION {
                return Err(db_error(format!(
                    "async daemon database schema mismatch: expected {SCHEMA_VERSION}, found {version}"
                )));
            }
            record_daemon_db_pool_state(
                "async",
                u64::from(db.pool.size()),
                u64::try_from(db.pool.num_idle()).unwrap_or(u64::MAX),
            );
            Ok(db)
        })
        .await
    }

    #[must_use]
    pub(crate) fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    /// Read the canonical schema version through `SQLx`.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn schema_version(&self) -> Result<String, CliError> {
        trace_async_db_operation("schema_version", "read", Some(&self.path), || async {
            record_daemon_db_pool_state(
                "async",
                u64::from(self.pool.size()),
                u64::try_from(self.pool.num_idle()).unwrap_or(u64::MAX),
            );
            async_bootstrap::read_async_schema_version(self.pool()).await
        })
        .await
    }

    /// Fast health counts for the daemon health endpoint.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn health_counts(&self) -> Result<(usize, usize, usize), CliError> {
        trace_async_db_operation("health_counts", "read", Some(&self.path), || async {
            record_daemon_db_pool_state(
                "async",
                u64::from(self.pool.size()),
                u64::try_from(self.pool.num_idle()).unwrap_or(u64::MAX),
            );
            let (project_count, worktree_count, session_count) =
                query_as::<_, (i64, i64, i64)>(HEALTH_COUNTS_SQL)
                    .fetch_one(self.pool())
                    .await
                    .map_err(|error| db_error(format!("read async health counts: {error}")))?;
            let counts = (
                usize_from_i64(project_count),
                usize_from_i64(worktree_count),
                usize_from_i64(session_count),
            );
            record_daemon_db_health_counts("async", counts.0, counts.1, counts.2);
            Ok(counts)
        })
        .await
    }

    /// Load all project summaries with session counts and worktree info.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn list_project_summaries(
        &self,
    ) -> Result<Vec<daemon_protocol::ProjectSummary>, CliError> {
        use daemon_protocol::{ProjectSummary, WorktreeSummary};

        trace_async_db_operation(
            "list_project_summaries",
            "read",
            Some(&self.path),
            || async {
                record_daemon_db_pool_state(
                    "async",
                    u64::from(self.pool.size()),
                    u64::try_from(self.pool.num_idle()).unwrap_or(u64::MAX),
                );
                let rows = query_as::<_, AsyncProjectSummaryRow>(PROJECT_SUMMARIES_SQL)
                    .fetch_all(self.pool())
                    .await
                    .map_err(|error| db_error(format!("query async project summaries: {error}")))?;

                let mut grouped: BTreeMap<String, ProjectSummary> = BTreeMap::new();
                for row in rows {
                    let project = row.project();
                    let active_session_count = usize_from_i64(row.active_session_count);
                    let total_session_count = usize_from_i64(row.total_session_count);
                    let project_id = project.summary_project_id();
                    let entry =
                        grouped
                            .entry(project_id.clone())
                            .or_insert_with(|| ProjectSummary {
                                project_id,
                                name: project.summary_project_name(),
                                project_dir: project.summary_project_dir(),
                                context_root: project.summary_context_root(),
                                active_session_count: 0,
                                total_session_count: 0,
                                worktrees: Vec::new(),
                            });

                    if project.is_worktree && total_session_count > 0 {
                        entry.worktrees.push(WorktreeSummary {
                            checkout_id: project.checkout_id.clone(),
                            name: project
                                .worktree_name
                                .clone()
                                .unwrap_or_else(|| project.checkout_name.clone()),
                            checkout_root: project
                                .project_dir
                                .as_ref()
                                .map_or_else(String::new, |path| path.display().to_string()),
                            context_root: project.context_root.display().to_string(),
                            active_session_count,
                            total_session_count,
                        });
                    }

                    entry.active_session_count += active_session_count;
                    entry.total_session_count += total_session_count;
                }

                let mut summaries: Vec<_> = grouped
                    .into_values()
                    .filter(|summary| summary.total_session_count > 0)
                    .collect();
                for summary in &mut summaries {
                    summary
                        .worktrees
                        .sort_by(|left, right| left.name.cmp(&right.name));
                }
                Ok(summaries)
            },
        )
        .await
    }

    /// Load all session summaries for the sessions list endpoint.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn list_session_summaries(
        &self,
    ) -> Result<Vec<daemon_protocol::SessionSummary>, CliError> {
        trace_async_db_operation(
            "list_session_summaries",
            "read",
            Some(&self.path),
            || async {
                record_daemon_db_pool_state(
                    "async",
                    u64::from(self.pool.size()),
                    u64::try_from(self.pool.num_idle()).unwrap_or(u64::MAX),
                );
                let rows = query_as::<_, AsyncSessionSummaryRow>(SESSION_SUMMARIES_SQL)
                    .fetch_all(self.pool())
                    .await
                    .map_err(|error| db_error(format!("query async session summaries: {error}")))?;

                let mut summaries = Vec::new();
                for row in rows {
                    summaries.push(row.into_summary(self).await?);
                }
                Ok(summaries)
            },
        )
        .await
    }

    /// Resolve a session into a `ResolvedSession` using the canonical async DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    pub(crate) async fn resolve_session(
        &self,
        session_id: &str,
    ) -> Result<Option<daemon_index::ResolvedSession>, CliError> {
        trace_async_db_operation("resolve_session", "read", Some(&self.path), || async {
            record_daemon_db_pool_state(
                "async",
                u64::from(self.pool.size()),
                u64::try_from(self.pool.num_idle()).unwrap_or(u64::MAX),
            );
            let row = query_as::<_, AsyncResolvedSessionRow>(RESOLVE_SESSION_SQL)
                .bind(session_id)
                .fetch_optional(self.pool())
                .await
                .map_err(|error| {
                    db_error(format!("resolve async session {session_id}: {error}"))
                })?;
            match row {
                Some(row) => row.into_resolved_session(self).await.map(Some),
                None => Ok(None),
            }
        })
        .await
    }
}

#[derive(sqlx::FromRow)]
struct AsyncProjectSummaryRow {
    project_id: String,
    name: String,
    project_dir: Option<String>,
    repository_root: Option<String>,
    context_root: String,
    checkout_id: String,
    checkout_name: String,
    is_worktree: bool,
    worktree_name: Option<String>,
    active_session_count: i64,
    total_session_count: i64,
}

impl AsyncProjectSummaryRow {
    fn project(&self) -> DiscoveredProject {
        DiscoveredProject {
            project_id: self.project_id.clone(),
            name: self.name.clone(),
            project_dir: self.project_dir.as_deref().map(PathBuf::from),
            repository_root: self.repository_root.as_deref().map(PathBuf::from),
            checkout_id: self.checkout_id.clone(),
            checkout_name: self.checkout_name.clone(),
            context_root: PathBuf::from(&self.context_root),
            is_worktree: self.is_worktree,
            worktree_name: self.worktree_name.clone(),
        }
    }
}

#[derive(sqlx::FromRow)]
#[allow(dead_code)]
struct AsyncSessionSummaryRow {
    session_id: String,
    title: String,
    context: String,
    status: String,
    created_at: String,
    updated_at: String,
    last_activity_at: Option<String>,
    leader_id: Option<String>,
    observe_id: Option<String>,
    pending_leader_transfer_json: Option<String>,
    metrics_json: String,
    state_json: String,
    project_id: String,
    project_name: String,
    project_dir: Option<String>,
    repository_root: Option<String>,
    context_root: String,
    checkout_id: String,
    checkout_name: String,
    is_worktree: bool,
    worktree_name: Option<String>,
}

impl AsyncSessionSummaryRow {
    async fn into_summary(
        self,
        db: &AsyncDaemonDb,
    ) -> Result<daemon_protocol::SessionSummary, CliError> {
        let mut state: SessionState = serde_json::from_str(&self.state_json)
            .map_err(|error| db_error(format!("parse session state: {error}")))?;
        let project = DiscoveredProject {
            project_id: self.project_id,
            name: self.project_name,
            project_dir: self.project_dir.as_deref().map(PathBuf::from),
            repository_root: self.repository_root.as_deref().map(PathBuf::from),
            checkout_id: self.checkout_id,
            checkout_name: self.checkout_name,
            context_root: PathBuf::from(self.context_root),
            is_worktree: self.is_worktree,
            worktree_name: self.worktree_name,
        };
        if canonicalize_active_session_without_leader(&mut state, &utc_now()) {
            db.save_session_state(&project.project_id, &state).await?;
        }
        Ok(daemon_protocol::SessionSummary {
            project_id: project.summary_project_id(),
            project_name: project.summary_project_name(),
            project_dir: project.summary_project_dir(),
            context_root: project.summary_context_root(),
            worktree_path: state.worktree_path.to_string_lossy().into_owned(),
            shared_path: state.shared_path.to_string_lossy().into_owned(),
            origin_path: state.origin_path.to_string_lossy().into_owned(),
            branch_ref: state.branch_ref.clone(),
            session_id: state.session_id,
            title: state.title,
            context: state.context,
            status: state.status,
            created_at: state.created_at,
            updated_at: state.updated_at,
            last_activity_at: state.last_activity_at,
            leader_id: state.leader_id,
            observe_id: state.observe_id,
            pending_leader_transfer: state.pending_leader_transfer,
            external_origin: state
                .external_origin
                .map(|path| path.to_string_lossy().into_owned()),
            adopted_at: state.adopted_at,
            metrics: state.metrics,
        })
    }
}

#[derive(sqlx::FromRow)]
struct AsyncResolvedSessionRow {
    state_json: String,
    project_id: String,
    project_name: String,
    project_dir: Option<String>,
    repository_root: Option<String>,
    checkout_id: String,
    checkout_name: String,
    context_root: String,
    is_worktree: bool,
    worktree_name: Option<String>,
}

impl AsyncResolvedSessionRow {
    async fn into_resolved_session(
        self,
        db: &AsyncDaemonDb,
    ) -> Result<daemon_index::ResolvedSession, CliError> {
        let mut state: SessionState = serde_json::from_str(&self.state_json)
            .map_err(|error| db_error(format!("parse session state: {error}")))?;
        let project = DiscoveredProject {
            project_id: self.project_id,
            name: self.project_name,
            project_dir: self.project_dir.as_deref().map(PathBuf::from),
            repository_root: self.repository_root.as_deref().map(PathBuf::from),
            checkout_id: self.checkout_id,
            checkout_name: self.checkout_name,
            context_root: PathBuf::from(self.context_root),
            is_worktree: self.is_worktree,
            worktree_name: self.worktree_name,
        };
        if canonicalize_active_session_without_leader(&mut state, &utc_now()) {
            db.save_session_state(&project.project_id, &state).await?;
        }
        Ok(daemon_index::ResolvedSession { project, state })
    }
}
