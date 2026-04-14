use std::collections::BTreeMap;

use super::super::index::{self, DiscoveredProject, ResolvedSession};
use super::super::protocol::{ProjectSummary, SessionSummary, WorktreeSummary};
use crate::errors::CliError;
use crate::session::types::SessionStatus;

type SessionCounts = (usize, usize);

fn increment_session_counts(
    counts: &mut BTreeMap<String, SessionCounts>,
    key: String,
    status: SessionStatus,
) {
    let entry = counts.entry(key).or_insert((0, 0));
    entry.1 += 1;
    if status == SessionStatus::Active {
        entry.0 += 1;
    }
}

fn collect_project_counts(
    sessions: Vec<ResolvedSession>,
) -> (
    BTreeMap<String, SessionCounts>,
    BTreeMap<String, SessionCounts>,
) {
    let mut project_counts = BTreeMap::new();
    let mut worktree_counts = BTreeMap::new();

    for session in sessions {
        increment_session_counts(
            &mut project_counts,
            session.project.summary_project_id(),
            session.state.status,
        );
        if session.project.is_worktree {
            increment_session_counts(
                &mut worktree_counts,
                session.project.checkout_id.clone(),
                session.state.status,
            );
        }
    }

    (project_counts, worktree_counts)
}

fn project_summary_entry<'a>(
    grouped: &'a mut BTreeMap<String, ProjectSummary>,
    project: &DiscoveredProject,
) -> &'a mut ProjectSummary {
    let project_id = project.summary_project_id();
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
        })
}

fn worktree_summary(
    project: &DiscoveredProject,
    worktree_counts: &BTreeMap<String, SessionCounts>,
) -> Option<WorktreeSummary> {
    if !project.is_worktree {
        return None;
    }

    let (active_session_count, total_session_count) = worktree_counts
        .get(&project.checkout_id)
        .copied()
        .unwrap_or((0, 0));
    if total_session_count == 0 {
        return None;
    }

    Some(WorktreeSummary {
        checkout_id: project.checkout_id.clone(),
        name: project.checkout_name.clone(),
        checkout_root: project
            .project_dir
            .as_ref()
            .map_or_else(String::new, |path| path.display().to_string()),
        context_root: project.context_root.display().to_string(),
        active_session_count,
        total_session_count,
    })
}

/// Build summaries for all discovered projects.
///
/// # Errors
/// Returns `CliError` on discovery or parse failures.
pub fn project_summaries() -> Result<Vec<ProjectSummary>, CliError> {
    let projects = index::discover_projects()?;
    let sessions = index::discover_sessions_for(&projects, true)?;
    let (project_counts, worktree_counts) = collect_project_counts(sessions);

    let mut grouped = BTreeMap::<String, ProjectSummary>::new();
    for project in projects {
        let entry = project_summary_entry(&mut grouped, &project);
        if let Some(summary) = worktree_summary(&project, &worktree_counts) {
            entry.worktrees.push(summary);
        }
    }

    let mut summaries: Vec<_> = grouped
        .into_values()
        .map(|mut summary| {
            let (active_session_count, total_session_count) = project_counts
                .get(&summary.project_id)
                .copied()
                .unwrap_or((0, 0));
            summary.active_session_count = active_session_count;
            summary.total_session_count = total_session_count;
            summary
                .worktrees
                .sort_by(|left, right| left.name.cmp(&right.name));
            summary
        })
        .filter(|summary| summary.total_session_count > 0)
        .collect();
    summaries.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(summaries)
}

/// Build summaries for all sessions across discovered projects.
///
/// # Errors
/// Returns `CliError` on discovery or parse failures.
pub fn session_summaries(include_all: bool) -> Result<Vec<SessionSummary>, CliError> {
    let mut sessions: Vec<SessionSummary> = index::discover_sessions(include_all)?
        .into_iter()
        .map(|session| summary_from_resolved(&session))
        .collect();
    sessions.sort_by(|left, right| right.updated_at.cmp(&left.updated_at));
    Ok(sessions)
}

pub(super) fn summary_from_resolved(resolved: &ResolvedSession) -> SessionSummary {
    SessionSummary {
        project_id: resolved.project.summary_project_id(),
        project_name: resolved.project.summary_project_name(),
        project_dir: resolved.project.summary_project_dir(),
        context_root: resolved.project.summary_context_root(),
        checkout_id: resolved.project.checkout_id.clone(),
        checkout_root: resolved
            .project
            .project_dir
            .as_ref()
            .map_or_else(String::new, |path| path.display().to_string()),
        is_worktree: resolved.project.is_worktree,
        worktree_name: resolved.project.worktree_name.clone(),
        session_id: resolved.state.session_id.clone(),
        title: resolved.state.title.clone(),
        context: resolved.state.context.clone(),
        status: resolved.state.status,
        created_at: resolved.state.created_at.clone(),
        updated_at: resolved.state.updated_at.clone(),
        last_activity_at: resolved.state.last_activity_at.clone(),
        leader_id: resolved.state.leader_id.clone(),
        observe_id: resolved.state.observe_id.clone(),
        pending_leader_transfer: resolved.state.pending_leader_transfer.clone(),
        metrics: resolved.state.metrics.clone(),
    }
}
