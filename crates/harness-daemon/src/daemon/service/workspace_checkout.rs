//! Create a checkout for a durable workspace, with no Session behind it.
//!
//! This is the Session-free half of what `session_setup::prepare_session` does:
//! resolve the origin, make a linked worktree, and discover the project the
//! worker will actually run in. What it deliberately does *not* do is write
//! `state.json`, register an active Session, or touch the sessions tree at all
//! - the checkout lives under `<data-root>/working-copies/`, because the
//! startup orphan sweep deletes anything under `sessions/` that has no
//! `state.json`.

use std::fs;
use std::path::{Path, PathBuf};

use harness_daemon_db_queries::WorkspaceCheckoutRequest;
use harness_workspace::git::identity::resolve_git_checkout_identity;

use crate::daemon::index;
use crate::sandbox;
use crate::workspace::layout::{CheckoutLayout, WorkingCopyLayout, working_copies_root};
use crate::workspace::worktree::WorktreeController;
use crate::workspace::{ensure_non_indexable, harness_data_root, project_resolver};
use harness_kernel::errors::{CliError, CliErrorKind};

/// What dispatch reserved before any of it existed on disk.
pub(crate) struct WorkspaceCheckoutPlan {
    pub(crate) daemon_id: String,
    pub(crate) working_copy_id: String,
    /// Origin the checkout branches from. Sandboxed callers pass a bookmark id
    /// here, exactly as session start does.
    pub(crate) project_dir: String,
    pub(crate) base_ref: Option<String>,
}

pub(crate) struct PreparedWorkspaceCheckout {
    pub(crate) request: WorkspaceCheckoutRequest,
    pub(crate) layout: WorkingCopyLayout,
    pub(crate) canonical_origin: PathBuf,
}

/// # Errors
/// Returns [`CliError`] when the origin cannot be resolved, the worktree cannot
/// be created, or the resulting checkout is not a checkout git recognizes.
pub(crate) fn prepare_workspace_checkout(
    plan: &WorkspaceCheckoutPlan,
) -> Result<PreparedWorkspaceCheckout, CliError> {
    // The scope guard MUST stay alive while the origin is touched: worktree
    // creation shells out against it, and the identity read below walks from
    // the new checkout back into it.
    let project_scope = sandbox::resolve_project_input(&plan.project_dir)?;
    let canonical_origin = project_scope.path().to_path_buf();

    let data_root = harness_data_root();
    ensure_non_indexable(&data_root).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "mark harness data root non-indexable: {error}"
        )))
    })?;
    let copies_root = working_copies_root(&data_root);
    fs::create_dir_all(&copies_root).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "create working copies root '{}': {error}",
            copies_root.display()
        )))
    })?;
    let project_name =
        project_resolver::resolve_name(&canonical_origin, &copies_root).map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "resolve project name for '{}': {error}",
                canonical_origin.display()
            )))
        })?;
    let layout = WorkingCopyLayout {
        working_copies_root: copies_root,
        project_name: project_name.clone(),
        working_copy_id: plan.working_copy_id.clone(),
    };
    fs::create_dir_all(layout.project_dir()).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "create project working copies dir '{}': {error}",
            layout.project_dir().display()
        )))
    })?;
    project_resolver::write_origin_marker(&layout.project_dir(), &canonical_origin).map_err(
        |error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "write project .origin marker for '{}': {error}",
                layout.project_dir().display()
            )))
        },
    )?;

    ensure_checkout(&canonical_origin, &layout, plan.base_ref.as_deref())?;

    // Identity comes from the new checkout, not the origin: two dispatches
    // against one repository must land in two workspaces, and the workspace key
    // is the checkout. Read it while the grant still covers the origin the
    // worktree points back at.
    let project = index::discovered_project_for_checkout(&layout.workspace());
    let worktree_path = canonical_worktree_path(&layout)?;

    drop(project_scope);
    Ok(PreparedWorkspaceCheckout {
        request: WorkspaceCheckoutRequest {
            daemon_id: plan.daemon_id.clone(),
            project,
            working_copy_id: plan.working_copy_id.clone(),
            origin_path: canonical_origin.to_string_lossy().into_owned(),
            project_name,
            worktree_path,
            branch_ref: layout.branch_ref(),
        },
        layout,
        canonical_origin,
    })
}

/// Make the checkout, or adopt the one a previous attempt left behind.
///
/// A preparation retries under the same reserved id, so an existing directory
/// is the normal case after a crash rather than an error. It is only reusable
/// when git still recognizes it as this branch's worktree; a half-written one
/// is destroyed and remade, which is what keeps a retry from stacking a second
/// checkout beside a broken first.
fn ensure_checkout(
    origin: &Path,
    layout: &WorkingCopyLayout,
    base_ref: Option<&str>,
) -> Result<(), CliError> {
    if layout.workspace().exists() {
        if checkout_is_usable(layout) {
            return Ok(());
        }
        WorktreeController::destroy(origin, layout).map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "remove incomplete workspace checkout: {error}"
            )))
        })?;
    }
    WorktreeController::create(origin, layout, base_ref).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "create workspace checkout: {error}"
        )))
    })
}

fn checkout_is_usable(layout: &WorkingCopyLayout) -> bool {
    resolve_git_checkout_identity(&layout.workspace()).is_some_and(|identity| {
        identity.is_worktree() && identity.worktree_name() == Some(layout.working_copy_id.as_str())
    })
}

fn canonical_worktree_path(layout: &WorkingCopyLayout) -> Result<String, CliError> {
    layout
        .workspace()
        .canonicalize()
        .map(|path| path.to_string_lossy().into_owned())
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("resolve workspace checkout path: {error}")).into()
        })
}

/// Remove a checkout this module created. Best effort: compensation records the
/// release either way, and a checkout git already forgot must not block it.
pub(crate) fn discard_workspace_checkout(origin: &Path, layout: &WorkingCopyLayout) {
    if let Err(error) = WorktreeController::destroy(origin, layout) {
        tracing::warn!(
            path = %layout.workspace().display(),
            %error,
            "workspace checkout cleanup failed"
        );
    }
}

/// Rebuild the layout for a checkout recorded earlier, so compensation and
/// recovery can address it without replaying discovery.
#[must_use]
pub(crate) fn recorded_layout(project_name: &str, working_copy_id: &str) -> WorkingCopyLayout {
    WorkingCopyLayout {
        working_copies_root: working_copies_root(&harness_data_root()),
        project_name: project_name.to_string(),
        working_copy_id: working_copy_id.to_string(),
    }
}
