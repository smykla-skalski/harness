use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use fs_err as fs;

use harness_kernel::errors::{CliError, CliErrorKind};
use crate::session::storage;
use crate::workspace::layout::sessions_root as workspace_sessions_root;
use crate::workspace::{
    canonical_checkout_root, harness_data_root, project_context_dir, resolve_git_checkout_identity,
};

use super::contexts::{infer_checkout_identity, repair_context_root};
use super::{DiscoveredProject, project_context_dir_name};

#[must_use]
pub fn projects_root() -> PathBuf {
    harness_data_root().join("projects")
}

/// Fast counts for the health endpoint. Reads directory entries only - no git
/// operations, no JSON parsing, no state loading.
#[must_use]
pub fn fast_counts() -> (usize, usize, usize) {
    let (mut project_count, worktree_count, mut session_count) = legacy_fast_counts();
    let (new_projects, new_sessions) = new_layout_fast_counts();
    project_count += new_projects;
    session_count += new_sessions;
    (project_count, worktree_count, session_count)
}

fn legacy_fast_counts() -> (usize, usize, usize) {
    let root = projects_root();
    if !root.is_dir() {
        return (0, 0, 0);
    }
    let Ok(entries) = fs::read_dir(&root) else {
        return (0, 0, 0);
    };
    let context_roots: Vec<_> = entries
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().ok().is_some_and(|kind| kind.is_dir()))
        .map(|entry| entry.path())
        .collect();
    let mut project_count = 0;
    let mut session_count = 0;
    let mut worktree_count = 0;
    for context_root in &context_roots {
        let mut context_session_count = 0;
        let sessions_dir = context_root.join("orchestration").join("sessions");
        if let Ok(sessions) = fs::read_dir(sessions_dir) {
            context_session_count = sessions
                .filter_map(Result::ok)
                .filter(|entry| entry.file_type().ok().is_some_and(|kind| kind.is_dir()))
                .count();
        }
        if context_session_count == 0 {
            continue;
        }
        session_count += context_session_count;
        project_count += 1;
        let origin_path = context_root.join("project-origin.json");
        if let Ok(data) = fs::read_to_string(&origin_path)
            && (data.contains("\"is_worktree\":true") || data.contains("\"is_worktree\": true"))
        {
            worktree_count += 1;
        }
    }
    (project_count, worktree_count, session_count)
}

fn new_layout_fast_counts() -> (usize, usize) {
    let root = workspace_sessions_root(&harness_data_root());
    let Ok(entries) = fs::read_dir(&root) else {
        return (0, 0);
    };
    let mut project_count = 0;
    let mut session_count = 0;
    for project_entry in entries.flatten() {
        if !project_entry
            .file_type()
            .ok()
            .is_some_and(|kind| kind.is_dir())
        {
            continue;
        }
        let Ok(sessions) = fs::read_dir(project_entry.path()) else {
            continue;
        };
        let this_session_count = sessions
            .filter_map(Result::ok)
            .filter(|entry| entry.file_type().ok().is_some_and(|kind| kind.is_dir()))
            .count();
        if this_session_count == 0 {
            continue;
        }
        project_count += 1;
        session_count += this_session_count;
    }
    (project_count, session_count)
}

/// Discover harness project context roots on disk.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn discover_projects() -> Result<Vec<DiscoveredProject>, CliError> {
    let root = projects_root();
    if !root.is_dir() {
        return Ok(Vec::new());
    }

    let raw_context_roots: Vec<_> = fs::read_dir(&root)
        .map_err(|error| CliErrorKind::workflow_io(format!("read daemon projects root: {error}")))?
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().ok().is_some_and(|kind| kind.is_dir()))
        .map(|entry| entry.path())
        .collect();

    let mut projects = Vec::new();
    let mut seen_context_roots = BTreeSet::new();
    for raw_context_root in raw_context_roots {
        let Some(context_root) = repair_context_root(&raw_context_root)? else {
            continue;
        };
        if !seen_context_roots.insert(context_root.clone()) {
            continue;
        }
        let project = build_discovered_project(&context_root)
            .unwrap_or_else(|| fallback_project(&context_root));
        projects.push(project);
    }

    projects.sort_by(|left, right| {
        left.name
            .cmp(&right.name)
            .then(left.checkout_name.cmp(&right.checkout_name))
    });
    Ok(projects)
}

/// Build a `DiscoveredProject` from an existing `context_root` directory.
///
/// Used by callers (e.g. the watch path) that have a transcript path under
/// `<context_root>/orchestration/...` and need to scope a session lookup to
/// the project's bucket without reloading the full discovery list.
#[must_use]
pub fn discovered_project_for_context_root(context_root: &Path) -> DiscoveredProject {
    build_discovered_project(context_root).unwrap_or_else(|| fallback_project(context_root))
}

#[must_use]
pub fn discovered_project_for_checkout(project_dir: &Path) -> DiscoveredProject {
    let checkout_root = canonical_checkout_root(project_dir);
    let context_root = project_context_dir(&checkout_root);
    let checkout_id = project_context_dir_name(&context_root).unwrap_or_default();

    if let Some(identity) = resolve_git_checkout_identity(&checkout_root) {
        let repository_project_id =
            project_context_dir_name(&project_context_dir(&identity.repository_root))
                .unwrap_or_default();
        let name = identity.repository_root.file_name().map_or_else(
            || repository_project_id.clone(),
            |name| name.to_string_lossy().to_string(),
        );
        let is_worktree = identity.is_worktree();
        let worktree_name = identity.worktree_name().map(ToString::to_string);
        let checkout_name = if is_worktree {
            worktree_name.clone().unwrap_or_else(|| {
                identity
                    .checkout_root
                    .file_name()
                    .map_or_else(String::new, |name| name.to_string_lossy().to_string())
            })
        } else {
            "main".to_string()
        };

        return DiscoveredProject {
            project_id: checkout_id.clone(),
            name,
            project_dir: Some(identity.checkout_root),
            repository_root: Some(identity.repository_root),
            checkout_id,
            checkout_name,
            context_root,
            is_worktree,
            worktree_name,
        };
    }

    // A sandboxed daemon reaches the checkout only while a folder grant is
    // held, so a released grant fails the read above. Falling straight through
    // would register the checkout as its own repository root; the recorded
    // origin still holds the identity it was registered under.
    if let Some(project) = recorded_git_project(&context_root) {
        return project;
    }

    let name = checkout_root.file_name().map_or_else(
        || checkout_id.clone(),
        |name| name.to_string_lossy().to_string(),
    );
    DiscoveredProject {
        project_id: checkout_id.clone(),
        name,
        project_dir: Some(checkout_root.clone()),
        repository_root: Some(checkout_root),
        checkout_id,
        checkout_name: "Directory".to_string(),
        context_root,
        is_worktree: false,
        worktree_name: None,
    }
}

/// Rebuild a checkout's identity from its recorded origin, but only when that
/// origin recorded a git repository root. A plain directory has no identity to
/// restore and must keep registering as a directory.
fn recorded_git_project(context_root: &Path) -> Option<DiscoveredProject> {
    let origin = storage::load_project_origin(context_root)?;
    origin.repository_root.as_ref()?;
    build_discovered_project(context_root)
}

fn fallback_project(context_root: &Path) -> DiscoveredProject {
    let project_id = project_context_dir_name(context_root).unwrap_or_default();
    let name = context_root.file_name().map_or_else(
        || project_id.clone(),
        |name| name.to_string_lossy().to_string(),
    );
    DiscoveredProject {
        project_id: project_id.clone(),
        name,
        project_dir: None,
        repository_root: None,
        checkout_id: project_id,
        checkout_name: "Unknown".to_string(),
        context_root: context_root.to_path_buf(),
        is_worktree: false,
        worktree_name: None,
    }
}

fn build_discovered_project(context_root: &Path) -> Option<DiscoveredProject> {
    let identity = infer_checkout_identity(context_root)?;
    let repository_project_id =
        project_context_dir_name(&project_context_dir(&identity.repository_root))
            .unwrap_or_default();
    let name = identity.repository_root.file_name().map_or_else(
        || repository_project_id.clone(),
        |name| name.to_string_lossy().to_string(),
    );
    let checkout_id = project_context_dir_name(context_root).unwrap_or_default();
    let checkout_name = if identity.is_worktree {
        identity.worktree_name.clone().unwrap_or_else(|| {
            identity
                .checkout_root
                .file_name()
                .map_or_else(String::new, |name| name.to_string_lossy().to_string())
        })
    } else {
        "main".to_string()
    };

    Some(DiscoveredProject {
        project_id: checkout_id.clone(),
        name,
        project_dir: Some(identity.checkout_root),
        repository_root: Some(identity.repository_root),
        checkout_id,
        checkout_name,
        context_root: context_root.to_path_buf(),
        is_worktree: identity.is_worktree,
        worktree_name: identity.worktree_name,
    })
}
