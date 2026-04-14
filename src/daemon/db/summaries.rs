use super::{
    BTreeMap, CliError, DaemonDb, DiscoveredProject, Path, PathBuf, SessionState, SessionStatus,
    daemon_index, daemon_protocol, db_error, project_context_dir, project_context_id,
    usize_from_i64,
};

impl DaemonDb {
    /// Return the number of sessions in the database.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub fn session_count(&self) -> Result<i64, CliError> {
        self.conn
            .query_row("SELECT COUNT(*) FROM sessions", [], |row| row.get(0))
            .map_err(|error| db_error(format!("count sessions: {error}")))
    }

    /// Return the number of rows in the projects table.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn project_count(&self) -> Result<i64, CliError> {
        self.conn
            .query_row("SELECT COUNT(*) FROM projects", [], |row| row.get(0))
            .map_err(|error| db_error(format!("count projects: {error}")))
    }

    // -- Read query methods for API endpoints --

    /// Fast counts for the health endpoint.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn health_counts(&self) -> Result<(usize, usize, usize), CliError> {
        self.conn
            .query_row(
                "SELECT
                    COUNT(DISTINCT COALESCE(NULLIF(p.repository_root, ''), p.project_dir, p.project_id)) AS project_count,
                    COUNT(DISTINCT CASE WHEN p.is_worktree = 1 THEN p.checkout_id END) AS worktree_count,
                    COUNT(DISTINCT s.session_id) AS session_count
                 FROM sessions s
                 JOIN projects p ON p.project_id = s.project_id",
                [],
                |row| {
                    Ok((
                        usize_from_i64(row.get(0)?),
                        usize_from_i64(row.get(1)?),
                        usize_from_i64(row.get(2)?),
                    ))
                },
            )
            .map_err(|error| db_error(format!("health counts: {error}")))
    }

    /// Load all project summaries with session counts and worktree info.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn list_project_summaries(&self) -> Result<Vec<daemon_protocol::ProjectSummary>, CliError> {
        use daemon_protocol::{ProjectSummary, WorktreeSummary};

        let mut statement = self
            .conn
            .prepare(
                "SELECT
                    p.project_id, p.name, p.project_dir, p.repository_root, p.context_root,
                    p.checkout_id, p.checkout_name, p.is_worktree, p.worktree_name,
                    COUNT(CASE WHEN s.is_active = 1 THEN 1 END) AS active_count,
                    COUNT(s.session_id) AS total_count
                 FROM projects p
                 LEFT JOIN sessions s ON s.project_id = p.project_id
                 GROUP BY p.project_id, p.checkout_id
                 ORDER BY p.name, p.checkout_name",
            )
            .map_err(|error| db_error(format!("prepare project summaries: {error}")))?;

        let rows = statement
            .query_map([], |row| {
                Ok(ProjectRow {
                    project_id: row.get(0)?,
                    name: row.get(1)?,
                    project_dir: row.get(2)?,
                    repository_root: row.get(3)?,
                    context_root: row.get(4)?,
                    checkout_id: row.get(5)?,
                    checkout_name: row.get(6)?,
                    is_worktree: row.get(7)?,
                    worktree_name: row.get(8)?,
                    active_session_count: usize_from_i64(row.get(9)?),
                    total_session_count: usize_from_i64(row.get(10)?),
                })
            })
            .map_err(|error| db_error(format!("query project summaries: {error}")))?;

        let all_rows: Vec<ProjectRow> = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| db_error(format!("read project row: {error}")))?;

        let mut grouped: BTreeMap<String, ProjectSummary> = BTreeMap::new();

        for row in all_rows {
            let project_id = row.summary_project_id();
            let entry = grouped
                .entry(project_id.clone())
                .or_insert_with(|| ProjectSummary {
                    project_id,
                    name: row.summary_project_name(),
                    project_dir: row.summary_project_dir(),
                    context_root: row.summary_context_root(),
                    active_session_count: 0,
                    total_session_count: 0,
                    worktrees: Vec::new(),
                });

            if row.is_worktree && row.total_session_count > 0 {
                entry.worktrees.push(WorktreeSummary {
                    checkout_id: row.checkout_id,
                    name: row.worktree_name.unwrap_or(row.checkout_name),
                    checkout_root: row.project_dir.unwrap_or_default(),
                    context_root: row.context_root,
                    active_session_count: row.active_session_count,
                    total_session_count: row.total_session_count,
                });
            }

            entry.active_session_count += row.active_session_count;
            entry.total_session_count += row.total_session_count;
        }

        let mut summaries: Vec<_> = grouped
            .into_values()
            .filter(|summary| summary.total_session_count > 0)
            .collect();
        for summary in &mut summaries {
            summary.worktrees.sort_by(|a, b| a.name.cmp(&b.name));
        }
        Ok(summaries)
    }

    /// Load all session summaries for the sessions list endpoint.
    /// Joins session state with project data to produce protocol-level summaries.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn list_session_summaries_full(
        &self,
    ) -> Result<Vec<daemon_protocol::SessionSummary>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT
                    s.session_id, s.title, s.context, s.status, s.created_at, s.updated_at,
                    s.last_activity_at, s.leader_id, s.observe_id,
                    s.pending_leader_transfer, s.metrics_json,
                    p.project_id, p.name, p.project_dir, p.repository_root, p.context_root,
                    p.checkout_id, p.checkout_name, p.is_worktree, p.worktree_name
                 FROM sessions s
                 JOIN projects p ON p.project_id = s.project_id
                 ORDER BY s.updated_at DESC",
            )
            .map_err(|error| db_error(format!("prepare session summaries: {error}")))?;

        let rows = statement
            .query_map([], |row| {
                Ok(SessionSummaryRow {
                    session_id: row.get(0)?,
                    title: row.get(1)?,
                    context: row.get(2)?,
                    status: row.get(3)?,
                    created_at: row.get(4)?,
                    updated_at: row.get(5)?,
                    last_activity_at: row.get(6)?,
                    leader_id: row.get(7)?,
                    observe_id: row.get(8)?,
                    pending_leader_transfer_json: row.get(9)?,
                    metrics_json: row.get(10)?,
                    project_id: row.get(11)?,
                    project_name: row.get(12)?,
                    project_dir: row.get(13)?,
                    repository_root: row.get(14)?,
                    context_root: row.get(15)?,
                    checkout_id: row.get(16)?,
                    checkout_name: row.get(17)?,
                    is_worktree: row.get(18)?,
                    worktree_name: row.get(19)?,
                })
            })
            .map_err(|error| db_error(format!("query session summaries: {error}")))?;

        let mut summaries = Vec::new();
        for row in rows {
            let row = row.map_err(|error| db_error(format!("read session row: {error}")))?;
            summaries.push(row.into_summary());
        }
        Ok(summaries)
    }

    /// Load all session states for the sessions list endpoint.
    ///
    /// # Errors
    /// Returns [`CliError`] on query failure.
    pub fn list_session_summaries(&self) -> Result<Vec<SessionState>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT s.state_json FROM sessions s
                 JOIN projects p ON p.project_id = s.project_id
                 ORDER BY s.updated_at DESC",
            )
            .map_err(|error| db_error(format!("prepare session list: {error}")))?;

        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|error| db_error(format!("query session list: {error}")))?;

        let mut sessions = Vec::new();
        for row in rows {
            let json = row.map_err(|error| db_error(format!("read session row: {error}")))?;
            let state: SessionState = serde_json::from_str(&json)
                .map_err(|error| db_error(format!("parse session state: {error}")))?;
            sessions.push(state);
        }
        Ok(sessions)
    }

    /// Resolve a session into a `ResolvedSession` using the DB instead of
    /// filesystem discovery.
    ///
    /// # Errors
    /// Returns [`CliError`] on query or parse failure.
    pub fn resolve_session(
        &self,
        session_id: &str,
    ) -> Result<Option<daemon_index::ResolvedSession>, CliError> {
        let result = self.conn.query_row(
            "SELECT s.state_json, p.project_id, p.name, p.project_dir, p.repository_root,
                    p.checkout_id, p.checkout_name, p.context_root, p.is_worktree, p.worktree_name
             FROM sessions s
             JOIN projects p ON p.project_id = s.project_id
             WHERE s.session_id = ?1",
            [session_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, String>(7)?,
                    row.get::<_, bool>(8)?,
                    row.get::<_, Option<String>>(9)?,
                ))
            },
        );

        match result {
            Ok((
                state_json,
                project_id,
                name,
                project_dir,
                repository_root,
                checkout_id,
                checkout_name,
                context_root,
                is_worktree,
                worktree_name,
            )) => {
                let state: SessionState = serde_json::from_str(&state_json)
                    .map_err(|error| db_error(format!("parse session state: {error}")))?;
                let project = DiscoveredProject {
                    project_id,
                    name,
                    project_dir: project_dir.map(PathBuf::from),
                    repository_root: repository_root.map(PathBuf::from),
                    checkout_id,
                    checkout_name,
                    context_root: PathBuf::from(context_root),
                    is_worktree,
                    worktree_name,
                };
                Ok(Some(daemon_index::ResolvedSession { project, state }))
            }
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(db_error(format!("resolve session: {error}"))),
        }
    }
}

struct ProjectRow {
    project_id: String,
    name: String,
    project_dir: Option<String>,
    repository_root: Option<String>,
    context_root: String,
    checkout_id: String,
    checkout_name: String,
    is_worktree: bool,
    worktree_name: Option<String>,
    active_session_count: usize,
    total_session_count: usize,
}

struct SessionSummaryRow {
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

impl ProjectRow {
    fn summary_project_id(&self) -> String {
        summary_project_id(&self.project_id, self.repository_root.as_deref())
    }

    fn summary_project_name(&self) -> String {
        summary_project_name(&self.name, self.repository_root.as_deref())
    }

    fn summary_project_dir(&self) -> Option<String> {
        summary_project_dir(self.project_dir.as_deref(), self.repository_root.as_deref())
    }

    fn summary_context_root(&self) -> String {
        summary_context_root(&self.context_root, self.repository_root.as_deref())
    }
}

impl SessionSummaryRow {
    fn into_summary(self) -> daemon_protocol::SessionSummary {
        use daemon_protocol::SessionSummary;

        let status = match self.status.as_str() {
            "active" => SessionStatus::Active,
            "paused" => SessionStatus::Paused,
            _ => SessionStatus::Ended,
        };
        let pending_leader_transfer = self
            .pending_leader_transfer_json
            .and_then(|json| serde_json::from_str(&json).ok());
        let metrics = serde_json::from_str(&self.metrics_json).unwrap_or_default();
        let checkout_root = self.project_dir.clone().unwrap_or_default();
        let project_id = summary_project_id(&self.project_id, self.repository_root.as_deref());
        let project_name =
            summary_project_name(&self.project_name, self.repository_root.as_deref());
        let project_dir =
            summary_project_dir(self.project_dir.as_deref(), self.repository_root.as_deref());
        let context_root =
            summary_context_root(&self.context_root, self.repository_root.as_deref());
        let worktree_name = self
            .worktree_name
            .or_else(|| self.is_worktree.then_some(self.checkout_name));

        SessionSummary {
            project_id,
            project_name,
            project_dir,
            context_root,
            checkout_id: self.checkout_id,
            checkout_root,
            is_worktree: self.is_worktree,
            worktree_name,
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
        }
    }
}

fn summary_project_id(project_id: &str, repository_root: Option<&str>) -> String {
    repository_path(repository_root)
        .and_then(project_context_id)
        .unwrap_or_else(|| project_id.to_string())
}

fn summary_project_name(name: &str, repository_root: Option<&str>) -> String {
    repository_path(repository_root)
        .and_then(Path::file_name)
        .map_or_else(
            || name.to_string(),
            |name| name.to_string_lossy().to_string(),
        )
}

fn summary_project_dir(project_dir: Option<&str>, repository_root: Option<&str>) -> Option<String> {
    repository_root
        .filter(|path| !path.trim().is_empty())
        .or(project_dir.filter(|path| !path.trim().is_empty()))
        .map(ToString::to_string)
}

fn summary_context_root(context_root: &str, repository_root: Option<&str>) -> String {
    repository_path(repository_root).map_or_else(
        || context_root.to_string(),
        |root| project_context_dir(root).display().to_string(),
    )
}

fn repository_path(repository_root: Option<&str>) -> Option<&Path> {
    repository_root
        .filter(|path| !path.trim().is_empty())
        .map(Path::new)
}
