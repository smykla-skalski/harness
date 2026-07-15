use serde_json::json;

use crate::daemon::protocol::CodexRunSnapshot;
use crate::errors::CliError;
use crate::git::GitRepository;
use crate::session::types::{SessionState, TaskStatus};

use super::handle::{CodexControllerHandle, lock_db, record_snapshot_event};

const WORKTREE_BASELINE_EVENT: &str = "agent/worktree_baseline";
const COMPLETION_DETAIL_LIMIT: usize = 2_000;

enum WorktreeBaseline {
    Clean(String),
    Dirty,
    Unavailable,
}

impl CodexControllerHandle {
    pub(super) fn completed_run_has_evidence(
        &self,
        run: &CodexRunSnapshot,
    ) -> Result<bool, CliError> {
        if !requires_completion_evidence(run) || worktree_changed_since_baseline(run) {
            return Ok(true);
        }
        self.bound_task_has_completion_evidence(run)
    }

    fn bound_task_has_completion_evidence(
        &self,
        run: &CodexRunSnapshot,
    ) -> Result<bool, CliError> {
        let session_id = run.session_id.clone();
        let run_async = run.clone();
        if let Some(result) = self.run_with_async_db(|async_db| async move {
            Ok(async_db.resolve_session(&session_id).await?.is_some_and(|resolved| {
                bound_task_has_completion_evidence(&resolved.state, &run_async)
            }))
        }) {
            return result;
        }
        let db = self.db()?;
        let db = lock_db(&db)?;
        Ok(db
            .load_session_state_for_mutation(&run.session_id)?
            .is_some_and(|state| bound_task_has_completion_evidence(&state, run)))
    }
}

pub(super) fn record_clean_worktree_baseline(snapshot: &mut CodexRunSnapshot) {
    let (tree, summary) = match clean_worktree_tree(&snapshot.project_dir) {
        WorktreeBaseline::Clean(tree) => {
            (Some(tree), "Recorded clean worker worktree baseline")
        }
        WorktreeBaseline::Dirty => (None, "Worker worktree was not clean at turn start"),
        WorktreeBaseline::Unavailable => (
            None,
            "Worker worktree baseline could not be computed at turn start",
        ),
    };
    let payload = json!({ "tree": tree });
    record_snapshot_event(
        snapshot,
        WORKTREE_BASELINE_EVENT,
        summary.to_string(),
        &payload,
    );
}

pub(super) fn requires_completion_evidence(run: &CodexRunSnapshot) -> bool {
    run.task_id.is_some() && run.session_agent_id.is_some()
}

pub(super) fn worktree_changed_since_baseline(run: &CodexRunSnapshot) -> bool {
    let Some(baseline_tree) = baseline_tree(run) else {
        return false;
    };
    let Some((current_tree, clean)) = current_worktree_state(&run.project_dir) else {
        return false;
    };
    !clean || current_tree != baseline_tree
}

pub(super) fn bound_task_has_completion_evidence(
    state: &SessionState,
    run: &CodexRunSnapshot,
) -> bool {
    let (Some(task_id), Some(agent_id)) = (run.task_id.as_deref(), run.session_agent_id.as_deref())
    else {
        return false;
    };
    state.tasks.get(task_id).is_some_and(|task| {
        task.status == TaskStatus::Done
            || (matches!(task.status, TaskStatus::AwaitingReview | TaskStatus::InReview)
                && task
                    .awaiting_review
                    .as_ref()
                    .is_some_and(|review| review.submitter_agent_id == agent_id))
    })
}

pub(super) fn missing_completion_evidence_error(run: &CodexRunSnapshot) -> String {
    let detail = run
        .final_message
        .as_deref()
        .or(run.latest_summary.as_deref())
        .map(str::trim)
        .filter(|detail| !detail.is_empty());
    let prefix = "Codex turn completed without submit-for-review or a worktree change";
    detail.map_or_else(
        || prefix.to_string(),
        |detail| format!("{prefix}: {}", truncate_chars(detail, COMPLETION_DETAIL_LIMIT)),
    )
}

fn baseline_tree(run: &CodexRunSnapshot) -> Option<&str> {
    run.events
        .iter()
        .rev()
        .find(|event| event.kind == WORKTREE_BASELINE_EVENT)
        .and_then(|event| event.payload.get("tree"))
        .and_then(|value| value.as_str())
}

fn clean_worktree_tree(project_dir: &str) -> WorktreeBaseline {
    match current_worktree_state(project_dir) {
        Some((tree, true)) => WorktreeBaseline::Clean(tree),
        Some((_, false)) => WorktreeBaseline::Dirty,
        None => WorktreeBaseline::Unavailable,
    }
}

fn current_worktree_state(project_dir: &str) -> Option<(String, bool)> {
    let repository = GitRepository::discover(project_dir.as_ref()).ok()?;
    let clean = !repository.has_changes_including_untracked().ok()?;
    let tree = repository.resolve_revision_to_commit("HEAD^{tree}").ok()?;
    Some((tree, clean))
}

fn truncate_chars(value: &str, limit: usize) -> String {
    let mut chars = value.chars();
    let truncated: String = chars.by_ref().take(limit).collect();
    if chars.next().is_some() {
        format!("{truncated}…")
    } else {
        truncated
    }
}
