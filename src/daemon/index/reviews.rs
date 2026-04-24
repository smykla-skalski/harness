//! File-discovery helpers for task review records.
//!
//! Split out from `sessions.rs` so the file-review surface has a stable home
//! and so `sessions.rs` stays under the repo-wide file-length budget.

use crate::errors::CliError;
use crate::session::storage;
use crate::session::types::Review;

use super::DiscoveredProject;
use super::io::read_json_lines;
use super::paths::task_reviews_path;

/// Load task review records from either the repository helper or direct JSONL.
///
/// Search priority mirrors `load_task_checkpoints`: repository-layout
/// candidates first (for real harness projects), then fall back to the
/// historical context-root path used by older imports.
///
/// # Errors
/// Returns [`CliError`] on parse or I/O failures.
pub fn load_task_reviews(
    project: &DiscoveredProject,
    session_id: &str,
    task_id: &str,
) -> Result<Vec<Review>, CliError> {
    if let Some(project_dir) = project.project_dir.as_deref() {
        for layout in storage::layout_candidates_from_project_dir(project_dir, session_id)? {
            let reviews = storage::load_reviews(&layout, task_id)?;
            if !reviews.is_empty() {
                return Ok(reviews);
            }
        }
    } else {
        for layout in
            storage::layout_candidates_from_context_root(&project.context_root, session_id)
        {
            let reviews = storage::load_reviews(&layout, task_id)?;
            if !reviews.is_empty() {
                return Ok(reviews);
            }
        }
    }
    read_json_lines(
        &task_reviews_path(&project.context_root, session_id, task_id),
        "task reviews",
    )
}
