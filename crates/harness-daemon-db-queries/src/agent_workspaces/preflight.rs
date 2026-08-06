use std::collections::{BTreeMap, BTreeSet};

use harness_protocol::daemon::summaries::{
    AgentWorkspaceAvailability, AgentWorkspaceConflict, AgentWorkspaceConflictKind,
};

use super::availability::{RecordedCheckout, recorded_checkout_availability};
use super::candidate::{Candidate, Lifecycle, classify_candidate, compare_candidates};
use super::identity::{digest_fields, manifest_digest, project_scope_id, source_snapshot_changed};
use super::shadow::shadow_digest;
use super::source::{ExistingWorkspaceSource, LegacyCandidateRow};

pub(super) const AGENT_WORKSPACE_MIGRATION_VERSION: i64 = 1;

#[derive(Debug)]
pub(super) struct PreflightResult {
    pub daemon_id: String,
    pub plans: Vec<WorkspacePlan>,
    pub conflicts: Vec<AgentWorkspaceConflict>,
    pub source_project_ids: Vec<String>,
    pub ownerless_updates: Vec<OwnerlessUpdate>,
}

#[derive(Debug)]
pub(super) struct OwnerlessUpdate {
    pub workspace_id: String,
    pub availability: AgentWorkspaceAvailability,
    pub shadow_digest: String,
}

#[derive(Debug)]
pub(super) struct WorkspacePlan {
    pub workspace_id: String,
    pub daemon_id: String,
    pub project_scope_id: String,
    pub checkout_id: String,
    pub source_project_id: String,
    pub project_name: String,
    pub checkout_name: String,
    pub project_dir: Option<String>,
    pub repository_root: Option<String>,
    pub context_root: String,
    pub is_worktree: bool,
    pub worktree_name: Option<String>,
    pub availability: AgentWorkspaceAvailability,
    pub selected_session_id: String,
    pub created_at: Option<String>,
    pub manifest_digest: String,
    pub idempotency_key: String,
    pub candidates: Vec<Candidate>,
}

pub(super) fn preflight(
    daemon_id: &str,
    rows: Vec<LegacyCandidateRow>,
    existing: &BTreeMap<(String, String), ExistingWorkspaceSource>,
) -> PreflightResult {
    let mut groups: BTreeMap<(String, String), Vec<LegacyCandidateRow>> = BTreeMap::new();
    let mut source_project_ids = rows
        .iter()
        .map(|row| row.source_project_id.clone())
        .collect::<Vec<_>>();
    source_project_ids.sort();
    source_project_ids.dedup();
    for row in rows {
        let project_scope_id = project_scope_id(&row);
        groups
            .entry((project_scope_id, row.checkout_id.clone()))
            .or_default()
            .push(row);
    }

    let mut plans = Vec::new();
    let mut conflicts = Vec::new();
    let mut ownerless_updates = Vec::new();
    let mut visited = BTreeSet::new();
    for ((project_scope_id, checkout_id), group) in groups {
        let key = (project_scope_id.clone(), checkout_id.clone());
        visited.insert(key.clone());
        let current = existing.get(&key);
        let prior_identity = group.first().and_then(|row| {
            existing.iter().find_map(|(existing_key, workspace)| {
                (existing_key != &key && workspace.source_project_id == row.source_project_id)
                    .then_some(workspace)
            })
        });
        match preflight_group(
            daemon_id,
            &project_scope_id,
            &checkout_id,
            &group,
            current,
            prior_identity,
        ) {
            Ok(plan) => plans.push(plan),
            Err(conflict) => conflicts.push(*conflict),
        }
    }
    for (key, workspace) in existing {
        if visited.contains(key) {
            continue;
        }
        match preflight_ownerless(daemon_id, key, workspace) {
            Ok(Some(update)) => ownerless_updates.push(update),
            Ok(None) => {}
            Err(conflict) => conflicts.push(*conflict),
        }
    }
    PreflightResult {
        daemon_id: daemon_id.to_string(),
        plans,
        conflicts,
        source_project_ids,
        ownerless_updates,
    }
}

fn preflight_ownerless(
    daemon_id: &str,
    key: &(String, String),
    workspace: &ExistingWorkspaceSource,
) -> Result<Option<OwnerlessUpdate>, Box<AgentWorkspaceConflict>> {
    if workspace.stored_shadow_digest != workspace.computed_shadow_digest {
        return Err(Box::new(conflict(
            daemon_id,
            &key.0,
            &key.1,
            AgentWorkspaceConflictKind::SourceDisagreement,
            workspace.source_digests.keys().cloned().collect(),
            "durable workspace shadow is corrupted without a legacy candidate".to_string(),
        )));
    }
    let availability = recorded_checkout_availability(RecordedCheckout {
        project_dir: workspace.shadow.project_dir.as_deref(),
        repository_root: workspace.shadow.repository_root.as_deref(),
        is_worktree: workspace.shadow.is_worktree == 1,
        worktree_name: workspace.shadow.worktree_name.as_deref(),
    })
    .map_err(|detail| {
        Box::new(conflict(
            daemon_id,
            &key.0,
            &key.1,
            AgentWorkspaceConflictKind::SourceDisagreement,
            workspace.source_digests.keys().cloned().collect(),
            format!("durable workspace checkout cannot be verified: {detail}"),
        ))
    })?;
    if workspace.shadow.availability == availability_label(availability) {
        return Ok(None);
    }
    let mut refreshed = workspace.shadow.clone();
    refreshed.availability = availability_label(availability).to_string();
    Ok(Some(OwnerlessUpdate {
        workspace_id: workspace.workspace_id.clone(),
        availability,
        shadow_digest: shadow_digest(&refreshed),
    }))
}

const fn availability_label(availability: AgentWorkspaceAvailability) -> &'static str {
    match availability {
        AgentWorkspaceAvailability::Available => "available",
        AgentWorkspaceAvailability::MissingWorktree => "missing_worktree",
    }
}

fn preflight_group(
    daemon_id: &str,
    project_scope_id: &str,
    checkout_id: &str,
    rows: &[LegacyCandidateRow],
    existing: Option<&ExistingWorkspaceSource>,
    prior_identity: Option<&ExistingWorkspaceSource>,
) -> Result<WorkspacePlan, Box<AgentWorkspaceConflict>> {
    validate_group_identity(
        daemon_id,
        project_scope_id,
        checkout_id,
        rows,
        prior_identity,
    )?;
    let candidates = classify_group(daemon_id, project_scope_id, checkout_id, rows)?;
    let selected = candidates
        .iter()
        .max_by(|left, right| compare_candidates(left, right))
        .expect("workspace group always has one candidate");
    let row = rows
        .iter()
        .find(|row| row.session_id == selected.session_id)
        .expect("selected candidate has a source row");
    let manifest_digest = manifest_digest(daemon_id, project_scope_id, checkout_id, &candidates);
    let workspace_id = format!(
        "agent-workspace-{}",
        digest_fields([daemon_id, project_scope_id, checkout_id])
    );
    let migration_version = AGENT_WORKSPACE_MIGRATION_VERSION.to_string();
    let idempotency_key = digest_fields([
        migration_version.as_str(),
        daemon_id,
        project_scope_id,
        checkout_id,
        &manifest_digest,
    ]);
    if let Some(existing) = existing {
        let source_changed = source_snapshot_changed(existing, &candidates);
        if existing.stored_shadow_digest != existing.computed_shadow_digest
            || existing.workspace_id != workspace_id
            || (existing.manifest_digest != manifest_digest && !source_changed)
            || (existing.manifest_digest == manifest_digest && source_changed)
        {
            return Err(Box::new(conflict(
                daemon_id,
                project_scope_id,
                checkout_id,
                AgentWorkspaceConflictKind::SourceDisagreement,
                session_ids(rows),
                "durable workspace disagrees with an unchanged legacy source".to_string(),
            )));
        }
    }
    Ok(WorkspacePlan {
        workspace_id,
        daemon_id: daemon_id.to_string(),
        project_scope_id: project_scope_id.to_string(),
        checkout_id: checkout_id.to_string(),
        source_project_id: row.source_project_id.clone(),
        project_name: row.project_name.clone(),
        checkout_name: row.checkout_name.clone(),
        project_dir: row.project_dir.clone(),
        repository_root: row.repository_root.clone(),
        context_root: row.context_root.clone(),
        is_worktree: row.is_worktree == 1,
        worktree_name: row.worktree_name.clone(),
        availability: selected.availability,
        selected_session_id: selected.session_id.clone(),
        created_at: existing.map(|workspace| workspace.created_at.clone()),
        manifest_digest,
        idempotency_key,
        candidates,
    })
}

fn validate_group_identity(
    daemon_id: &str,
    project_scope_id: &str,
    checkout_id: &str,
    rows: &[LegacyCandidateRow],
    prior_identity: Option<&ExistingWorkspaceSource>,
) -> Result<(), Box<AgentWorkspaceConflict>> {
    if let Some(detail) = inconsistent_project_provenance(rows) {
        return Err(Box::new(conflict(
            daemon_id,
            project_scope_id,
            checkout_id,
            AgentWorkspaceConflictKind::SourceDisagreement,
            session_ids(rows),
            detail,
        )));
    }
    if let Some(prior) = prior_identity {
        return Err(Box::new(conflict(
            daemon_id,
            project_scope_id,
            checkout_id,
            AgentWorkspaceConflictKind::SourceDisagreement,
            session_ids(rows),
            format!(
                "source project is already recorded by durable workspace {}",
                prior.workspace_id
            ),
        )));
    }
    Ok(())
}

fn classify_group(
    daemon_id: &str,
    project_scope_id: &str,
    checkout_id: &str,
    rows: &[LegacyCandidateRow],
) -> Result<Vec<Candidate>, Box<AgentWorkspaceConflict>> {
    let mut candidates = Vec::with_capacity(rows.len());
    for row in rows {
        match classify_candidate(row) {
            Ok(candidate) => candidates.push(candidate),
            Err(detail) => {
                return Err(Box::new(conflict(
                    daemon_id,
                    project_scope_id,
                    checkout_id,
                    AgentWorkspaceConflictKind::MalformedCandidate,
                    session_ids(rows),
                    detail,
                )));
            }
        }
    }
    let active = candidates
        .iter()
        .filter(|candidate| candidate.lifecycle == Lifecycle::Active)
        .count();
    if active > 1 {
        return Err(Box::new(conflict(
            daemon_id,
            project_scope_id,
            checkout_id,
            AgentWorkspaceConflictKind::ActiveOwnerCollision,
            session_ids(rows),
            format!("{active} legacy Sessions still carry live work"),
        )));
    }
    Ok(candidates)
}

fn session_ids(rows: &[LegacyCandidateRow]) -> Vec<String> {
    rows.iter().map(|row| row.session_id.clone()).collect()
}

fn inconsistent_project_provenance(rows: &[LegacyCandidateRow]) -> Option<String> {
    let first = rows.first()?;
    rows.iter().skip(1).find_map(|row| {
        let agrees = row.source_project_id == first.source_project_id
            && row.project_name == first.project_name
            && row.project_dir == first.project_dir
            && row.repository_root == first.repository_root
            && row.context_root == first.context_root
            && row.checkout_name == first.checkout_name
            && row.is_worktree == first.is_worktree
            && row.worktree_name == first.worktree_name;
        (!agrees).then(|| "legacy Sessions disagree on persisted project provenance".to_string())
    })
}

fn conflict(
    daemon_id: &str,
    project_scope_id: &str,
    checkout_id: &str,
    kind: AgentWorkspaceConflictKind,
    legacy_session_ids: Vec<String>,
    detail: String,
) -> AgentWorkspaceConflict {
    AgentWorkspaceConflict {
        daemon_id: daemon_id.to_string(),
        project_scope_id: project_scope_id.to_string(),
        checkout_id: checkout_id.to_string(),
        kind,
        legacy_session_ids,
        detail,
    }
}
