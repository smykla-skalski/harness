use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use sqlx::{FromRow, Sqlite, Transaction, query_as};
use std::collections::BTreeMap;

use super::shadow::{ShadowCandidate, ShadowWorkspace, shadow_digest};

const LEGACY_CANDIDATES_SQL: &str = "SELECT
    s.session_id,
    s.project_id AS source_project_id,
    s.schema_version,
    s.state_version,
    s.status,
    s.created_at,
    s.updated_at,
    s.last_activity_at,
    s.state_json,
    p.name AS project_name,
    p.project_dir,
    p.repository_root,
    p.context_root,
    p.checkout_id,
    p.checkout_name,
    p.is_worktree,
    p.worktree_name,
    p.updated_at AS project_updated_at,
    EXISTS (
        SELECT 1 FROM agents a
        WHERE a.session_id = s.session_id
          AND a.status IN ('active', 'idle', 'awaiting_review')
    ) AS has_live_agent,
    EXISTS (
        SELECT 1 FROM agent_tuis tui
        WHERE tui.session_id = s.session_id
          AND tui.status IN ('starting', 'running')
    ) AS has_live_tui,
    EXISTS (
        SELECT 1 FROM codex_runs run
        WHERE run.session_id = s.session_id
          AND run.status IN ('queued', 'running', 'waiting_approval')
    ) AS has_live_codex_run,
    EXISTS (
        SELECT 1 FROM agent_turn_runs turn
        WHERE turn.session_id = s.session_id
          AND turn.status IN ('queued', 'running')
    ) AS has_live_turn,
    EXISTS (
        SELECT 1 FROM signal_index signal
        WHERE signal.session_id = s.session_id
          AND signal.status IN ('pending', 'deferred')
    ) AS has_pending_signal,
    EXISTS (
        SELECT 1 FROM tasks task
        WHERE task.session_id = s.session_id
          AND task.deleted_at IS NULL
          AND task.status IN ('awaiting_review', 'in_review')
    ) AS has_review_obligation
FROM sessions s
JOIN projects p ON p.project_id = s.project_id
ORDER BY p.project_id, s.session_id";

const ACTIVITY_TIMESTAMPS_SQL: &str = "SELECT session_id, source, recorded_at
FROM (
    SELECT agent.session_id, 'agent' AS source,
           COALESCE(agent.last_activity_at, agent.updated_at) AS recorded_at
    FROM agents agent
    JOIN sessions source_session ON source_session.session_id = agent.session_id
    UNION ALL
    SELECT tui.session_id, 'agent_tui', tui.updated_at
    FROM agent_tuis tui
    JOIN sessions source_session ON source_session.session_id = tui.session_id
    UNION ALL
    SELECT run.session_id, 'codex_run', run.updated_at
    FROM codex_runs run
    JOIN sessions source_session ON source_session.session_id = run.session_id
    UNION ALL
    SELECT turn.session_id, 'agent_turn', turn.updated_at
    FROM agent_turn_runs turn
    JOIN sessions source_session ON source_session.session_id = turn.session_id
    UNION ALL
    SELECT task.session_id, 'task', task.updated_at
    FROM tasks task
    JOIN sessions source_session ON source_session.session_id = task.session_id
    UNION ALL
    SELECT review.session_id, 'task_review', review.recorded_at
    FROM task_reviews review
    JOIN sessions source_session ON source_session.session_id = review.session_id
)
ORDER BY session_id, source, recorded_at";

#[derive(Debug, Clone, FromRow)]
pub(super) struct LegacyCandidateRow {
    pub session_id: String,
    pub source_project_id: String,
    pub schema_version: i64,
    pub state_version: i64,
    pub status: String,
    pub created_at: String,
    pub updated_at: String,
    pub last_activity_at: Option<String>,
    pub state_json: String,
    pub project_name: String,
    pub project_dir: Option<String>,
    pub repository_root: Option<String>,
    pub context_root: String,
    pub checkout_id: String,
    pub checkout_name: String,
    pub is_worktree: i64,
    pub worktree_name: Option<String>,
    pub project_updated_at: String,
    pub has_live_agent: i64,
    pub has_live_tui: i64,
    pub has_live_codex_run: i64,
    pub has_live_turn: i64,
    pub has_pending_signal: i64,
    pub has_review_obligation: i64,
    #[sqlx(skip)]
    pub activity_timestamps: Vec<ActivityTimestamp>,
}

#[derive(Debug, Clone)]
pub(super) struct ActivityTimestamp {
    pub source: String,
    pub recorded_at: String,
}

#[derive(Debug, FromRow)]
struct ActivityTimestampRow {
    session_id: String,
    source: String,
    recorded_at: String,
}

#[derive(Debug, Clone)]
pub(super) struct ExistingWorkspaceSource {
    pub workspace_id: String,
    pub source_project_id: String,
    pub manifest_digest: String,
    pub stored_shadow_digest: String,
    pub computed_shadow_digest: String,
    pub created_at: String,
    pub source_digests: BTreeMap<String, String>,
    pub shadow: ShadowWorkspace,
}

#[derive(Debug, Clone, FromRow)]
struct ExistingWorkspaceRow {
    workspace_id: String,
    daemon_id: String,
    project_scope_id: String,
    checkout_id: String,
    source_project_id: String,
    project_name: String,
    checkout_name: String,
    project_dir: Option<String>,
    repository_root: Option<String>,
    context_root: String,
    is_worktree: i64,
    worktree_name: Option<String>,
    availability: String,
    selected_legacy_session_id: Option<String>,
    manifest_digest: String,
    shadow_digest: String,
    orchestration_authority: String,
    created_at: String,
}

#[derive(Debug, Clone, FromRow)]
struct ExistingProvenanceRow {
    workspace_id: String,
    session_id: String,
    lifecycle: String,
    checkout_availability: String,
    liveness_evidence: String,
    effective_activity_at: Option<String>,
    session_updated_at: String,
    session_created_at: String,
    source_digest: String,
    is_selected: i64,
}

pub(super) async fn load_candidates(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<Vec<LegacyCandidateRow>, CliError> {
    let mut candidates = query_as::<_, LegacyCandidateRow>(LEGACY_CANDIDATES_SQL)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load legacy workspace candidates: {error}")))?;
    let indices = candidates
        .iter()
        .enumerate()
        .map(|(index, candidate)| (candidate.session_id.clone(), index))
        .collect::<BTreeMap<_, _>>();
    let activities = query_as::<_, ActivityTimestampRow>(ACTIVITY_TIMESTAMPS_SQL)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load workspace activity timestamps: {error}")))?;
    for activity in activities {
        let Some(index) = indices.get(&activity.session_id).copied() else {
            continue;
        };
        candidates[index]
            .activity_timestamps
            .push(ActivityTimestamp {
                source: activity.source,
                recorded_at: activity.recorded_at,
            });
    }
    Ok(candidates)
}

pub(super) async fn load_existing_workspace_sources(
    transaction: &mut Transaction<'_, Sqlite>,
    daemon_id: &str,
) -> Result<BTreeMap<(String, String), ExistingWorkspaceSource>, CliError> {
    let rows = query_as::<_, ExistingWorkspaceRow>(
        "SELECT workspace_id, daemon_id, project_scope_id, checkout_id,
                source_project_id, project_name, checkout_name, project_dir,
                repository_root, context_root, is_worktree, worktree_name,
                availability, selected_legacy_session_id, manifest_digest,
                shadow_digest, orchestration_authority, created_at
         FROM agent_workspaces
         WHERE daemon_id = ?1
         ORDER BY project_scope_id, checkout_id",
    )
    .bind(daemon_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load existing workspace manifests: {error}")))?;
    let source_rows = query_as::<_, ExistingProvenanceRow>(
        "SELECT provenance.workspace_id, provenance.session_id, provenance.lifecycle,
                provenance.checkout_availability, provenance.liveness_evidence,
                provenance.effective_activity_at, provenance.session_updated_at,
                provenance.session_created_at, provenance.source_digest,
                provenance.is_selected
         FROM agent_workspace_legacy_sessions provenance
         JOIN agent_workspaces workspace ON workspace.workspace_id = provenance.workspace_id
         WHERE workspace.daemon_id = ?1
         ORDER BY provenance.workspace_id, provenance.session_id",
    )
    .bind(daemon_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load existing workspace source digests: {error}")))?;
    let mut provenance = BTreeMap::<String, Vec<ExistingProvenanceRow>>::new();
    for row in source_rows {
        provenance
            .entry(row.workspace_id.clone())
            .or_default()
            .push(row);
    }
    Ok(rows
        .into_iter()
        .map(|row| {
            let candidates = provenance.remove(&row.workspace_id).unwrap_or_default();
            let source_digests = candidates
                .iter()
                .map(|candidate| {
                    (
                        candidate.session_id.clone(),
                        candidate.source_digest.clone(),
                    )
                })
                .collect();
            let shadow = ShadowWorkspace {
                workspace_id: row.workspace_id.clone(),
                daemon_id: row.daemon_id.clone(),
                project_scope_id: row.project_scope_id.clone(),
                checkout_id: row.checkout_id.clone(),
                source_project_id: row.source_project_id.clone(),
                project_name: row.project_name.clone(),
                checkout_name: row.checkout_name.clone(),
                project_dir: row.project_dir.clone(),
                repository_root: row.repository_root.clone(),
                context_root: row.context_root.clone(),
                is_worktree: row.is_worktree,
                worktree_name: row.worktree_name.clone(),
                availability: row.availability.clone(),
                selected_legacy_session_id: row.selected_legacy_session_id.clone(),
                manifest_digest: row.manifest_digest.clone(),
                orchestration_authority: row.orchestration_authority.clone(),
                created_at: row.created_at.clone(),
                candidates: candidates.into_iter().map(Into::into).collect(),
            };
            let computed_shadow_digest = shadow_digest(&shadow);
            (
                (row.project_scope_id, row.checkout_id),
                ExistingWorkspaceSource {
                    workspace_id: row.workspace_id,
                    source_project_id: row.source_project_id,
                    manifest_digest: row.manifest_digest,
                    stored_shadow_digest: row.shadow_digest,
                    computed_shadow_digest,
                    created_at: row.created_at,
                    source_digests,
                    shadow,
                },
            )
        })
        .collect())
}

impl From<ExistingProvenanceRow> for ShadowCandidate {
    fn from(row: ExistingProvenanceRow) -> Self {
        Self {
            session_id: row.session_id,
            lifecycle: row.lifecycle,
            checkout_availability: row.checkout_availability,
            liveness_evidence: row.liveness_evidence,
            effective_activity_at: row.effective_activity_at,
            session_updated_at: row.session_updated_at,
            session_created_at: row.session_created_at,
            source_digest: row.source_digest,
            is_selected: row.is_selected,
        }
    }
}
