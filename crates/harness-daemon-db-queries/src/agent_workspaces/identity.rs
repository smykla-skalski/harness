use harness_session::index::DiscoveredProject;
use sha2::{Digest, Sha256};

use super::candidate::Candidate;
use super::preflight::AGENT_WORKSPACE_MIGRATION_VERSION;
use super::source::{ExistingWorkspaceSource, LegacyCandidateRow};

pub(super) fn project_scope_id(row: &LegacyCandidateRow) -> String {
    DiscoveredProject {
        project_id: row.source_project_id.clone(),
        name: row.project_name.clone(),
        project_dir: row.project_dir.as_deref().map(Into::into),
        repository_root: row.repository_root.as_deref().map(Into::into),
        checkout_id: row.checkout_id.clone(),
        checkout_name: row.checkout_name.clone(),
        context_root: row.context_root.as_str().into(),
        is_worktree: row.is_worktree == 1,
        worktree_name: row.worktree_name.clone(),
    }
    .summary_project_id()
}

pub(super) fn manifest_digest(
    daemon_id: &str,
    project_scope_id: &str,
    checkout_id: &str,
    candidates: &[Candidate],
) -> String {
    let mut fields = vec![
        AGENT_WORKSPACE_MIGRATION_VERSION.to_string(),
        daemon_id.to_string(),
        project_scope_id.to_string(),
        checkout_id.to_string(),
    ];
    for candidate in candidates {
        fields.extend([
            candidate.session_id.clone(),
            candidate.lifecycle.as_str().to_string(),
            candidate.source_digest.clone(),
        ]);
    }
    digest_fields(fields.iter().map(String::as_str))
}

pub(super) fn source_snapshot_changed(
    existing: &ExistingWorkspaceSource,
    candidates: &[Candidate],
) -> bool {
    existing.source_digests.len() != candidates.len()
        || candidates.iter().any(|candidate| {
            existing.source_digests.get(&candidate.session_id) != Some(&candidate.source_digest)
        })
}

pub(crate) fn digest_fields<'a>(fields: impl IntoIterator<Item = &'a str>) -> String {
    let mut hasher = Sha256::new();
    for field in fields {
        hasher.update(field.len().to_be_bytes());
        hasher.update(field.as_bytes());
    }
    hex::encode(hasher.finalize())
}
