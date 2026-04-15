use std::time::Duration;

use sqlx::migrate::{Migration, Migrator};
use sqlx::pool::PoolOptions;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqliteSynchronous};
use sqlx::{Sqlite, SqlitePool, query, query_as, query_scalar};

use super::{
    BTreeMap, CliError, Connection, DaemonDb, DiscoveredProject, Path, PathBuf, SCHEMA_VERSION,
    SessionState, daemon_index, daemon_protocol, db_error, usize_from_i64,
};

const ASYNC_DB_ACQUIRE_TIMEOUT: Duration = Duration::from_secs(5);
const ASYNC_DB_BUSY_TIMEOUT: Duration = Duration::from_secs(5);
const ASYNC_DB_MAX_CONNECTIONS: u32 = 8;
const TABLE_EXISTS_SQL: &str =
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name = ?1";
const SCHEMA_VERSION_SQL: &str = "SELECT value FROM schema_meta WHERE key = 'version'";
const SQLX_MIGRATIONS_TABLE_SQL: &str = "
CREATE TABLE IF NOT EXISTS _sqlx_migrations (
    version BIGINT PRIMARY KEY,
    description TEXT NOT NULL,
    installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    success BOOLEAN NOT NULL,
    checksum BLOB NOT NULL,
    execution_time BIGINT NOT NULL
)";
const SQLX_MIGRATION_VERSION_EXISTS_SQL: &str =
    "SELECT COUNT(*) FROM _sqlx_migrations WHERE version = ?1";
const INSERT_SQLX_MIGRATION_SQL: &str = "
INSERT INTO _sqlx_migrations (version, description, success, checksum, execution_time)
VALUES (?1, ?2, TRUE, ?3, 0)";
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
static DAEMON_DB_MIGRATOR: Migrator = sqlx::migrate!("./src/daemon/db/migrations");

/// Async `SQLx` pool over the canonical daemon `SQLite` database.
pub(crate) struct AsyncDaemonDb {
    pool: SqlitePool,
}

impl AsyncDaemonDb {
    /// Open the canonical daemon `SQLite` database through `SQLx`.
    ///
    /// # Errors
    /// Returns [`CliError`] when the pool or schema probe cannot be initialized.
    pub(crate) async fn connect(path: &Path) -> Result<Self, CliError> {
        prepare_legacy_schema(path)?;
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

        let db = Self { pool };
        db.ensure_schema().await?;
        let version = db.schema_version().await?;
        if version != SCHEMA_VERSION {
            return Err(db_error(format!(
                "async daemon database schema mismatch: expected {SCHEMA_VERSION}, found {version}"
            )));
        }
        Ok(db)
    }

    #[must_use]
    pub(crate) fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    async fn ensure_schema(&self) -> Result<(), CliError> {
        if !self.table_exists("schema_meta").await? {
            run_daemon_migrator(self.pool()).await?;
            return Ok(());
        }

        self.ensure_baseline_migration_recorded().await?;
        run_daemon_migrator(self.pool()).await
    }

    async fn ensure_baseline_migration_recorded(&self) -> Result<(), CliError> {
        if !self.table_exists("_sqlx_migrations").await? {
            query(SQLX_MIGRATIONS_TABLE_SQL)
                .execute(self.pool())
                .await
                .map_err(|error| db_error(format!("create async migration ledger: {error}")))?;
        }

        let baseline = baseline_migration()?;
        if self.migration_exists(baseline.version).await? {
            return Ok(());
        }

        query(INSERT_SQLX_MIGRATION_SQL)
            .bind(baseline.version)
            .bind(baseline.description.to_string())
            .bind(baseline.checksum.as_ref().to_vec())
            .execute(self.pool())
            .await
            .map_err(|error| db_error(format!("seed async migration ledger: {error}")))?;
        Ok(())
    }

    async fn table_exists(&self, table_name: &str) -> Result<bool, CliError> {
        query_scalar::<_, i64>(TABLE_EXISTS_SQL)
            .bind(table_name)
            .fetch_one(self.pool())
            .await
            .map(|count| count > 0)
            .map_err(|error| db_error(format!("check async table {table_name} existence: {error}")))
    }

    async fn migration_exists(&self, version: i64) -> Result<bool, CliError> {
        query_scalar::<_, i64>(SQLX_MIGRATION_VERSION_EXISTS_SQL)
            .bind(version)
            .fetch_one(self.pool())
            .await
            .map(|count| count > 0)
            .map_err(|error| {
                db_error(format!(
                    "check async migration {version} existence: {error}"
                ))
            })
    }

    /// Read the canonical schema version through `SQLx`.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn schema_version(&self) -> Result<String, CliError> {
        query_scalar::<_, String>(SCHEMA_VERSION_SQL)
            .fetch_one(self.pool())
            .await
            .map_err(|error| db_error(format!("read async schema version: {error}")))
    }

    /// Fast health counts for the daemon health endpoint.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn health_counts(&self) -> Result<(usize, usize, usize), CliError> {
        let (project_count, worktree_count, session_count) =
            query_as::<_, (i64, i64, i64)>(HEALTH_COUNTS_SQL)
                .fetch_one(self.pool())
                .await
                .map_err(|error| db_error(format!("read async health counts: {error}")))?;
        Ok((
            usize_from_i64(project_count),
            usize_from_i64(worktree_count),
            usize_from_i64(session_count),
        ))
    }

    /// Load all project summaries with session counts and worktree info.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn list_project_summaries(
        &self,
    ) -> Result<Vec<daemon_protocol::ProjectSummary>, CliError> {
        use daemon_protocol::{ProjectSummary, WorktreeSummary};

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
            let entry = grouped
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
    }

    /// Load all session summaries for the sessions list endpoint.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn list_session_summaries(
        &self,
    ) -> Result<Vec<daemon_protocol::SessionSummary>, CliError> {
        let rows = query_as::<_, AsyncSessionSummaryRow>(SESSION_SUMMARIES_SQL)
            .fetch_all(self.pool())
            .await
            .map_err(|error| db_error(format!("query async session summaries: {error}")))?;

        rows.into_iter()
            .map(AsyncSessionSummaryRow::into_summary)
            .collect()
    }

    /// Resolve a session into a `ResolvedSession` using the canonical async DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    pub(crate) async fn resolve_session(
        &self,
        session_id: &str,
    ) -> Result<Option<daemon_index::ResolvedSession>, CliError> {
        query_as::<_, AsyncResolvedSessionRow>(RESOLVE_SESSION_SQL)
            .bind(session_id)
            .fetch_optional(self.pool())
            .await
            .map_err(|error| db_error(format!("resolve async session {session_id}: {error}")))?
            .map(AsyncResolvedSessionRow::into_resolved_session)
            .transpose()
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
    fn into_summary(self) -> Result<daemon_protocol::SessionSummary, CliError> {
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
        let status = match self.status.as_str() {
            "active" => super::SessionStatus::Active,
            "paused" => super::SessionStatus::Paused,
            _ => super::SessionStatus::Ended,
        };
        let pending_leader_transfer = self
            .pending_leader_transfer_json
            .map(|json| {
                serde_json::from_str(&json)
                    .map_err(|error| db_error(format!("parse pending leader transfer: {error}")))
            })
            .transpose()?;
        let metrics = serde_json::from_str(&self.metrics_json)
            .map_err(|error| db_error(format!("parse session metrics: {error}")))?;
        let checkout_root = project
            .project_dir
            .as_ref()
            .map_or_else(String::new, |path| path.display().to_string());

        Ok(daemon_protocol::SessionSummary {
            project_id: project.summary_project_id(),
            project_name: project.summary_project_name(),
            project_dir: project.summary_project_dir(),
            context_root: project.summary_context_root(),
            checkout_id: project.checkout_id.clone(),
            checkout_root,
            is_worktree: project.is_worktree,
            worktree_name: project
                .worktree_name
                .clone()
                .or_else(|| project.is_worktree.then_some(project.checkout_name.clone())),
            session_id: self.session_id,
            title: self.title,
            context: self.context,
            status,
            created_at: self.created_at,
            updated_at: self.updated_at,
            last_activity_at: self.last_activity_at,
            leader_id: self.leader_id,
            observe_id: self.observe_id,
            pending_leader_transfer,
            metrics,
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
    fn into_resolved_session(self) -> Result<daemon_index::ResolvedSession, CliError> {
        let state: SessionState = serde_json::from_str(&self.state_json)
            .map_err(|error| db_error(format!("parse session state: {error}")))?;
        Ok(daemon_index::ResolvedSession {
            project: DiscoveredProject {
                project_id: self.project_id,
                name: self.project_name,
                project_dir: self.project_dir.as_deref().map(PathBuf::from),
                repository_root: self.repository_root.as_deref().map(PathBuf::from),
                checkout_id: self.checkout_id,
                checkout_name: self.checkout_name,
                context_root: PathBuf::from(self.context_root),
                is_worktree: self.is_worktree,
                worktree_name: self.worktree_name,
            },
            state,
        })
    }
}

fn prepare_legacy_schema(path: &Path) -> Result<(), CliError> {
    if !path.exists() {
        return Ok(());
    }

    let conn = Connection::open(path)
        .map_err(|error| db_error(format!("inspect async daemon database: {error}")))?;
    if !sync_table_exists(&conn, "schema_meta")? {
        return Ok(());
    }

    let version: String = conn
        .query_row(SCHEMA_VERSION_SQL, [], |row| row.get(0))
        .map_err(|error| db_error(format!("inspect async schema version: {error}")))?;
    drop(conn);

    if version != SCHEMA_VERSION {
        let _ = DaemonDb::open(path)?;
    }
    Ok(())
}

fn sync_table_exists(conn: &Connection, table_name: &str) -> Result<bool, CliError> {
    conn.query_row(TABLE_EXISTS_SQL, [table_name], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .map_err(|error| db_error(format!("check sync table {table_name} existence: {error}")))
}

fn baseline_migration() -> Result<&'static Migration, CliError> {
    DAEMON_DB_MIGRATOR
        .iter()
        .next()
        .ok_or_else(|| db_error("missing daemon async baseline migration"))
}

async fn run_daemon_migrator(pool: &SqlitePool) -> Result<(), CliError> {
    DAEMON_DB_MIGRATOR
        .run(pool)
        .await
        .map_err(|error| db_error(format!("run async daemon migrations: {error}")))
}
