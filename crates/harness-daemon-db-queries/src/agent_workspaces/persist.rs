use std::collections::{BTreeMap, BTreeSet};

use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use harness_protocol::daemon::summaries::{
    AgentWorkspaceAvailability, AgentWorkspaceConflict, AgentWorkspaceConflictKind,
    AgentWorkspaceListResponse, AgentWorkspaceOrchestrationAuthority, AgentWorkspaceProvenance,
    AgentWorkspaceSummary,
};
use harness_workspace::workspace::utc_now;
use sha2::{Digest, Sha256};
use sqlx::{FromRow, Sqlite, Transaction, query, query_as};

use super::preflight::{
    AGENT_WORKSPACE_MIGRATION_VERSION, OwnerlessUpdate, PreflightResult, WorkspacePlan,
};
use super::provenance::persist_workspace_provenance;
use super::retire::{clear_reconcile_queue, retire_deleted_legacy_correlations};
use super::shadow::plan_shadow_digest;

pub(super) async fn persist_preflight(
    transaction: &mut Transaction<'_, Sqlite>,
    result: &PreflightResult,
) -> Result<(), CliError> {
    let now = utc_now();
    if !result.conflicts.is_empty() {
        for conflict in &result.conflicts {
            persist_conflict(transaction, conflict, &now).await?;
        }
        return Ok(());
    }

    for update in &result.ownerless_updates {
        persist_ownerless_update(transaction, update, &now).await?;
    }
    retire_deleted_legacy_correlations(
        transaction,
        &result.daemon_id,
        &result.source_project_ids,
        &now,
    )
    .await?;
    for plan in &result.plans {
        persist_plan(transaction, plan, &now).await?;
    }
    clear_reconcile_queue(transaction, &result.source_project_ids).await
}

async fn persist_ownerless_update(
    transaction: &mut Transaction<'_, Sqlite>,
    update: &OwnerlessUpdate,
    now: &str,
) -> Result<(), CliError> {
    query(
        "UPDATE agent_workspaces
         SET availability = ?2, shadow_digest = ?3, updated_at = ?4
         WHERE workspace_id = ?1",
    )
    .bind(&update.workspace_id)
    .bind(availability_label(update.availability))
    .bind(&update.shadow_digest)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("refresh ownerless workspace availability: {error}")))?;
    Ok(())
}

async fn persist_plan(
    transaction: &mut Transaction<'_, Sqlite>,
    plan: &WorkspacePlan,
    now: &str,
) -> Result<(), CliError> {
    let created_at = plan.created_at.as_deref().unwrap_or(now);
    let shadow_digest = plan_shadow_digest(plan, created_at);
    query(
        "INSERT INTO agent_workspaces (
            workspace_id, daemon_id, project_scope_id, checkout_id, source_project_id,
            project_name, checkout_name, project_dir, repository_root, context_root,
            is_worktree, worktree_name, availability, selected_legacy_session_id,
            manifest_digest, shadow_digest, orchestration_authority, created_at, updated_at
         ) VALUES (
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
            ?15, ?16, 'legacy_session', ?17, ?18
         )
         ON CONFLICT(workspace_id) DO UPDATE SET
            source_project_id = excluded.source_project_id,
            project_name = excluded.project_name,
            checkout_name = excluded.checkout_name,
            project_dir = excluded.project_dir,
            repository_root = excluded.repository_root,
            context_root = excluded.context_root,
            is_worktree = excluded.is_worktree,
            worktree_name = excluded.worktree_name,
            availability = excluded.availability,
            selected_legacy_session_id = excluded.selected_legacy_session_id,
            manifest_digest = excluded.manifest_digest,
            shadow_digest = excluded.shadow_digest,
            orchestration_authority = 'legacy_session',
            updated_at = excluded.updated_at",
    )
    .bind(&plan.workspace_id)
    .bind(&plan.daemon_id)
    .bind(&plan.project_scope_id)
    .bind(&plan.checkout_id)
    .bind(&plan.source_project_id)
    .bind(&plan.project_name)
    .bind(&plan.checkout_name)
    .bind(&plan.project_dir)
    .bind(&plan.repository_root)
    .bind(&plan.context_root)
    .bind(plan.is_worktree)
    .bind(&plan.worktree_name)
    .bind(availability_label(plan.availability))
    .bind(&plan.selected_session_id)
    .bind(&plan.manifest_digest)
    .bind(&shadow_digest)
    .bind(created_at)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("persist durable agent workspace: {error}")))?;

    persist_workspace_provenance(transaction, plan).await?;
    persist_ready_journal(transaction, plan, now).await
}

async fn persist_ready_journal(
    transaction: &mut Transaction<'_, Sqlite>,
    plan: &WorkspacePlan,
    now: &str,
) -> Result<(), CliError> {
    let source_session_ids = serde_json::to_string(
        &plan
            .candidates
            .iter()
            .map(|candidate| candidate.session_id.as_str())
            .collect::<Vec<_>>(),
    )
    .map_err(|error| db_error(format!("serialize workspace source ids: {error}")))?;
    persist_journal(
        transaction,
        JournalRecord {
            daemon_id: &plan.daemon_id,
            project_scope_id: &plan.project_scope_id,
            checkout_id: &plan.checkout_id,
            workspace_id: Some(&plan.workspace_id),
            manifest_digest: &plan.manifest_digest,
            idempotency_key: &plan.idempotency_key,
            outcome: "ready",
            phase: "committed",
            blocker_kind: None,
            blocker_detail: None,
            source_session_ids: &source_session_ids,
            updated_at: now,
        },
    )
    .await
}

async fn persist_conflict(
    transaction: &mut Transaction<'_, Sqlite>,
    conflict: &AgentWorkspaceConflict,
    now: &str,
) -> Result<(), CliError> {
    let source_session_ids = serde_json::to_string(&conflict.legacy_session_ids)
        .map_err(|error| db_error(format!("serialize workspace conflict ids: {error}")))?;
    let manifest_digest = conflict_digest(conflict);
    let idempotency_key = conflict_digest_with_version(conflict);
    persist_journal(
        transaction,
        JournalRecord {
            daemon_id: &conflict.daemon_id,
            project_scope_id: &conflict.project_scope_id,
            checkout_id: &conflict.checkout_id,
            workspace_id: None,
            manifest_digest: &manifest_digest,
            idempotency_key: &idempotency_key,
            outcome: "blocked",
            phase: "preflighted",
            blocker_kind: Some(conflict_kind_label(conflict.kind)),
            blocker_detail: Some(&conflict.detail),
            source_session_ids: &source_session_ids,
            updated_at: now,
        },
    )
    .await
}

struct JournalRecord<'a> {
    daemon_id: &'a str,
    project_scope_id: &'a str,
    checkout_id: &'a str,
    workspace_id: Option<&'a str>,
    manifest_digest: &'a str,
    idempotency_key: &'a str,
    outcome: &'a str,
    phase: &'a str,
    blocker_kind: Option<&'a str>,
    blocker_detail: Option<&'a str>,
    source_session_ids: &'a str,
    updated_at: &'a str,
}

async fn persist_journal(
    transaction: &mut Transaction<'_, Sqlite>,
    record: JournalRecord<'_>,
) -> Result<(), CliError> {
    query(
        "INSERT INTO agent_workspace_reconciliation (
            daemon_id, project_scope_id, checkout_id, workspace_id, migration_version,
            manifest_digest, idempotency_key, outcome, phase, blocker_kind,
            blocker_detail, source_session_ids_json, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
         ON CONFLICT(daemon_id, project_scope_id, checkout_id) DO UPDATE SET
            workspace_id = excluded.workspace_id,
            migration_version = excluded.migration_version,
            manifest_digest = excluded.manifest_digest,
            idempotency_key = excluded.idempotency_key,
            outcome = excluded.outcome,
            phase = excluded.phase,
            blocker_kind = excluded.blocker_kind,
            blocker_detail = excluded.blocker_detail,
            source_session_ids_json = excluded.source_session_ids_json,
            updated_at = excluded.updated_at",
    )
    .bind(record.daemon_id)
    .bind(record.project_scope_id)
    .bind(record.checkout_id)
    .bind(record.workspace_id)
    .bind(AGENT_WORKSPACE_MIGRATION_VERSION)
    .bind(record.manifest_digest)
    .bind(record.idempotency_key)
    .bind(record.outcome)
    .bind(record.phase)
    .bind(record.blocker_kind)
    .bind(record.blocker_detail)
    .bind(record.source_session_ids)
    .bind(record.updated_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("persist workspace reconciliation journal: {error}")))?;
    Ok(())
}

#[derive(Debug, FromRow)]
struct StoredWorkspaceRow {
    workspace_id: String,
    daemon_id: String,
    project_scope_id: String,
    checkout_id: String,
    source_project_id: String,
    project_name: String,
    checkout_name: String,
    project_dir: Option<String>,
    context_root: String,
    is_worktree: bool,
    worktree_name: Option<String>,
    availability: String,
    selected_legacy_session_id: Option<String>,
    manifest_digest: String,
    orchestration_authority: String,
    created_at: String,
    updated_at: String,
}

pub(super) async fn load_response(
    transaction: &mut Transaction<'_, Sqlite>,
    daemon_id: &str,
    preflight: &PreflightResult,
) -> Result<AgentWorkspaceListResponse, CliError> {
    let rows = query_as::<_, StoredWorkspaceRow>(
        "SELECT workspace_id, daemon_id, project_scope_id, checkout_id,
                source_project_id, project_name, checkout_name, project_dir,
                context_root, is_worktree, worktree_name, availability,
                selected_legacy_session_id, manifest_digest, orchestration_authority,
                created_at, updated_at
         FROM agent_workspaces
         WHERE daemon_id = ?1
         ORDER BY project_name, checkout_name, workspace_id",
    )
    .bind(daemon_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load durable agent workspaces: {error}")))?;
    let provenance = load_legacy_session_ids(transaction, daemon_id).await?;
    let mut conflicts = preflight.conflicts.clone();
    let conflict_keys = conflicts
        .iter()
        .map(|conflict| {
            (
                conflict.project_scope_id.clone(),
                conflict.checkout_id.clone(),
            )
        })
        .collect::<BTreeSet<_>>();
    let conflict_session_ids = conflicts
        .iter()
        .flat_map(|conflict| conflict.legacy_session_ids.iter().cloned())
        .collect::<BTreeSet<_>>();
    let plans = preflight
        .plans
        .iter()
        .map(|plan| {
            (
                (plan.project_scope_id.clone(), plan.checkout_id.clone()),
                plan,
            )
        })
        .collect::<BTreeMap<_, _>>();
    let mut workspaces = Vec::new();
    for row in rows {
        let legacy_session_ids = provenance
            .get(&row.workspace_id)
            .cloned()
            .unwrap_or_default();
        let key = (row.project_scope_id.clone(), row.checkout_id.clone());
        if conflict_keys.contains(&key)
            || legacy_session_ids
                .iter()
                .any(|session_id| conflict_session_ids.contains(session_id))
        {
            continue;
        }
        if let Some(plan) = plans.get(&key)
            && plan.manifest_digest != row.manifest_digest
        {
            conflicts.push(AgentWorkspaceConflict {
                daemon_id: daemon_id.to_string(),
                project_scope_id: row.project_scope_id,
                checkout_id: row.checkout_id,
                kind: AgentWorkspaceConflictKind::SourceDisagreement,
                legacy_session_ids: plan
                    .candidates
                    .iter()
                    .map(|candidate| candidate.session_id.clone())
                    .collect(),
                detail: "durable workspace disagrees with the authoritative legacy source"
                    .to_string(),
            });
            continue;
        }
        workspaces.push(row.into_summary(legacy_session_ids)?);
    }
    conflicts.sort_by(|left, right| {
        left.project_scope_id
            .cmp(&right.project_scope_id)
            .then_with(|| left.checkout_id.cmp(&right.checkout_id))
    });
    Ok(AgentWorkspaceListResponse {
        workspaces,
        conflicts,
    })
}

async fn load_legacy_session_ids(
    transaction: &mut Transaction<'_, Sqlite>,
    daemon_id: &str,
) -> Result<BTreeMap<String, Vec<String>>, CliError> {
    let rows = query_as::<_, (String, String)>(
        "SELECT provenance.workspace_id, provenance.session_id
         FROM agent_workspace_legacy_sessions provenance
         JOIN agent_workspaces workspace ON workspace.workspace_id = provenance.workspace_id
         WHERE workspace.daemon_id = ?1
         ORDER BY provenance.workspace_id, provenance.session_id",
    )
    .bind(daemon_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load workspace Session provenance: {error}")))?;
    let mut grouped = BTreeMap::new();
    for (workspace_id, session_id) in rows {
        grouped
            .entry(workspace_id)
            .or_insert_with(Vec::new)
            .push(session_id);
    }
    Ok(grouped)
}

impl StoredWorkspaceRow {
    fn into_summary(
        self,
        legacy_session_ids: Vec<String>,
    ) -> Result<AgentWorkspaceSummary, CliError> {
        let availability = match self.availability.as_str() {
            "available" => AgentWorkspaceAvailability::Available,
            "missing_worktree" => AgentWorkspaceAvailability::MissingWorktree,
            value => return Err(db_error(format!("unknown workspace availability {value}"))),
        };
        let orchestration_authority = match self.orchestration_authority.as_str() {
            "no_owner" => AgentWorkspaceOrchestrationAuthority::NoOwner,
            "legacy_session" => AgentWorkspaceOrchestrationAuthority::LegacySession,
            "workspace" => AgentWorkspaceOrchestrationAuthority::Workspace,
            value => return Err(db_error(format!("unknown workspace authority {value}"))),
        };
        Ok(AgentWorkspaceSummary {
            workspace_id: self.workspace_id,
            project_name: self.project_name,
            checkout_name: self.checkout_name,
            checkout_root: self.project_dir,
            context_root: self.context_root,
            is_worktree: self.is_worktree,
            worktree_name: self.worktree_name,
            availability,
            orchestration_authority,
            provenance: AgentWorkspaceProvenance {
                daemon_id: self.daemon_id,
                project_scope_id: self.project_scope_id,
                checkout_id: self.checkout_id,
                source_project_id: self.source_project_id,
                legacy_session_ids,
                selected_legacy_session_id: self.selected_legacy_session_id,
                manifest_digest: self.manifest_digest,
            },
            created_at: self.created_at,
            updated_at: self.updated_at,
        })
    }
}

pub(super) const fn availability_label(availability: AgentWorkspaceAvailability) -> &'static str {
    match availability {
        AgentWorkspaceAvailability::Available => "available",
        AgentWorkspaceAvailability::MissingWorktree => "missing_worktree",
    }
}

const fn conflict_kind_label(kind: AgentWorkspaceConflictKind) -> &'static str {
    match kind {
        AgentWorkspaceConflictKind::ActiveOwnerCollision => "active_owner_collision",
        AgentWorkspaceConflictKind::MalformedCandidate => "malformed_candidate",
        AgentWorkspaceConflictKind::SourceDisagreement => "source_disagreement",
    }
}

fn conflict_digest(conflict: &AgentWorkspaceConflict) -> String {
    let mut hasher = Sha256::new();
    for field in [
        conflict.daemon_id.as_str(),
        conflict.project_scope_id.as_str(),
        conflict.checkout_id.as_str(),
        conflict_kind_label(conflict.kind),
        conflict.detail.as_str(),
    ] {
        hasher.update(field.len().to_be_bytes());
        hasher.update(field.as_bytes());
    }
    for session_id in &conflict.legacy_session_ids {
        hasher.update(session_id.len().to_be_bytes());
        hasher.update(session_id.as_bytes());
    }
    hex::encode(hasher.finalize())
}

fn conflict_digest_with_version(conflict: &AgentWorkspaceConflict) -> String {
    let mut hasher = Sha256::new();
    hasher.update(AGENT_WORKSPACE_MIGRATION_VERSION.to_be_bytes());
    hasher.update(conflict_digest(conflict));
    hex::encode(hasher.finalize())
}
