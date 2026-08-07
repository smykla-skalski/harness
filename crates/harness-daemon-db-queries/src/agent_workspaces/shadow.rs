use serde::Serialize;
use sha2::{Digest, Sha256};

use super::preflight::WorkspacePlan;

#[derive(Clone, Debug, Serialize)]
pub(crate) struct ShadowWorkspace {
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
    pub is_worktree: i64,
    pub worktree_name: Option<String>,
    pub availability: String,
    pub selected_legacy_session_id: Option<String>,
    pub manifest_digest: String,
    pub orchestration_authority: String,
    pub created_at: String,
    pub candidates: Vec<ShadowCandidate>,
}

#[derive(Clone, Debug, Serialize)]
pub(crate) struct ShadowCandidate {
    pub session_id: String,
    pub lifecycle: String,
    pub checkout_availability: String,
    pub liveness_evidence: String,
    pub effective_activity_at: Option<String>,
    pub session_updated_at: String,
    pub session_created_at: String,
    pub source_digest: String,
    pub is_selected: i64,
}

pub(super) fn plan_shadow_digest(plan: &WorkspacePlan, created_at: &str) -> String {
    shadow_digest(&ShadowWorkspace {
        workspace_id: plan.workspace_id.clone(),
        daemon_id: plan.daemon_id.clone(),
        project_scope_id: plan.project_scope_id.clone(),
        checkout_id: plan.checkout_id.clone(),
        source_project_id: plan.source_project_id.clone(),
        project_name: plan.project_name.clone(),
        checkout_name: plan.checkout_name.clone(),
        project_dir: plan.project_dir.clone(),
        repository_root: plan.repository_root.clone(),
        context_root: plan.context_root.clone(),
        is_worktree: i64::from(plan.is_worktree),
        worktree_name: plan.worktree_name.clone(),
        availability: availability_label(plan.availability).to_string(),
        selected_legacy_session_id: Some(plan.selected_session_id.clone()),
        manifest_digest: plan.manifest_digest.clone(),
        orchestration_authority: "legacy_session".to_string(),
        created_at: created_at.to_string(),
        candidates: plan
            .candidates
            .iter()
            .map(|candidate| ShadowCandidate {
                session_id: candidate.session_id.clone(),
                lifecycle: candidate.lifecycle.as_str().to_string(),
                checkout_availability: availability_label(candidate.availability).to_string(),
                liveness_evidence: candidate.liveness_evidence.clone(),
                effective_activity_at: candidate.effective_activity_at.clone(),
                session_updated_at: candidate.updated_at.clone(),
                session_created_at: candidate.created_at.clone(),
                source_digest: candidate.source_digest.clone(),
                is_selected: i64::from(candidate.session_id == plan.selected_session_id),
            })
            .collect(),
    })
}

pub(crate) fn shadow_digest(workspace: &ShadowWorkspace) -> String {
    let mut canonical = workspace.clone();
    canonical
        .candidates
        .sort_by(|left, right| left.session_id.cmp(&right.session_id));
    let encoded =
        serde_json::to_vec(&canonical).expect("shadow workspace serialization cannot fail");
    hex::encode(Sha256::digest(encoded))
}

const fn availability_label(
    availability: harness_protocol::daemon::summaries::AgentWorkspaceAvailability,
) -> &'static str {
    use harness_protocol::daemon::summaries::AgentWorkspaceAvailability;
    match availability {
        AgentWorkspaceAvailability::Available => "available",
        AgentWorkspaceAvailability::MissingWorktree => "missing_worktree",
    }
}
