use std::path::{Path, PathBuf};

use tokio::task::spawn_blocking;

use super::{concurrent, workflow_io};
use crate::daemon::db::TaskBoardRemoteAssignmentRecord;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::service::workspace_checkout;
use harness_daemon_db_queries::{
    AgentWorkingCopy, AsyncAgentWorkingCopyQueries, WorkspaceManagedAgentKind,
    WorkspaceMemberRegistration,
};
use harness_kernel::errors::CliError;
use harness_workspace::workspace::layout::{
    CheckoutLayout, WorkingCopyLayout, working_copies_root,
};
use harness_workspace::workspace::worktree::WorktreeController;
use harness_workspace::workspace::{harness_data_root, project_resolver};

use super::super::RemoteWorkerIdentity;

pub(super) async fn cleanup_executor_workspace(
    db: &AsyncDaemonDbHandle,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
) -> Result<(), CliError> {
    let Some(copy) = db
        .load_agent_working_copy(&identity.working_copy_id)
        .await?
    else {
        return destroy_orphan_executor_workspace(record, identity).await;
    };
    validate_cleanup_workspace(record, identity, &copy)?;
    record_workspace_runtime_stop(db, record, identity, &copy.workspace_id).await?;
    if !copy.released {
        let _ = db
            .release_agent_working_copy(&copy.working_copy_id, "remote assignment settled")
            .await?;
    }
    destroy_executor_workspace(copy).await
}

pub(super) async fn cleanup_unstarted_executor_workspace(
    db: &AsyncDaemonDbHandle,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
) -> Result<(), CliError> {
    let Some(copy) = db
        .load_agent_working_copy(&identity.working_copy_id)
        .await?
    else {
        return destroy_orphan_executor_workspace(record, identity).await;
    };
    validate_cleanup_workspace(record, identity, &copy)?;
    if !copy.released {
        let _ = db
            .release_agent_working_copy(&copy.working_copy_id, "remote start abandoned")
            .await?;
    }
    destroy_executor_workspace(copy).await
}

pub(super) fn validate_cleanup_workspace(
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
    copy: &AgentWorkingCopy,
) -> Result<(), CliError> {
    let expected_origin = PathBuf::from(
        record
            .executor_checkout_path
            .as_deref()
            .ok_or_else(|| concurrent("remote executor cleanup has no frozen checkout path"))?,
    )
    .canonicalize()
    .map_err(|error| workflow_io(format!("canonicalize remote cleanup origin: {error}")))?;
    let actual_origin = PathBuf::from(&copy.origin_path)
        .canonicalize()
        .map_err(|error| {
            workflow_io(format!("canonicalize remote working-copy origin: {error}"))
        })?;
    let receipt_matches = record.start_receipt.as_ref().is_none_or(|receipt| {
        receipt.workspace_id.as_deref() == Some(copy.workspace_id.as_str())
            && receipt.working_copy_id.as_deref() == Some(copy.working_copy_id.as_str())
            && receipt.project_dir == copy.worktree_path
    });
    if copy.working_copy_id != identity.working_copy_id
        || copy.branch_ref != format!("harness/{}", identity.working_copy_id)
        || expected_origin != actual_origin
        || !receipt_matches
    {
        return Err(concurrent(
            "remote executor cleanup working-copy identity mismatched",
        ));
    }
    Ok(())
}

async fn record_workspace_runtime_stop(
    db: &AsyncDaemonDbHandle,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
    workspace_id: &str,
) -> Result<(), CliError> {
    let offer = record.require_offer()?;
    let kind = if offer.launch.runtime == "openrouter" {
        WorkspaceManagedAgentKind::Acp
    } else {
        WorkspaceManagedAgentKind::Codex
    };
    let member_id = WorkspaceMemberRegistration {
        workspace_id: workspace_id.to_string(),
        kind,
        managed_agent_id: identity.run_id.clone(),
        runtime_kind: offer.launch.runtime.clone(),
        display_name: String::new(),
        assignment_id: None,
    }
    .member_id();
    db.record_workspace_member_runtime_stop(workspace_id, &member_id, "remote assignment settled")
        .await
}

async fn destroy_executor_workspace(copy: AgentWorkingCopy) -> Result<(), CliError> {
    let layout = workspace_checkout::recorded_layout(&copy.project_name, &copy.working_copy_id);
    if layout.workspace() != Path::new(&copy.worktree_path) {
        return Err(concurrent(
            "remote executor cleanup working-copy path mismatched",
        ));
    }
    let origin = PathBuf::from(copy.origin_path);
    spawn_blocking(move || destroy_workspace_layout(&origin, &layout))
        .await
        .map_err(|error| workflow_io(format!("join remote working-copy cleanup: {error}")))?
}

async fn destroy_orphan_executor_workspace(
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
) -> Result<(), CliError> {
    let origin = PathBuf::from(
        record
            .executor_checkout_path
            .as_deref()
            .ok_or_else(|| concurrent("remote executor cleanup has no frozen checkout path"))?,
    )
    .canonicalize()
    .map_err(|error| workflow_io(format!("canonicalize orphan cleanup origin: {error}")))?;
    let root = working_copies_root(&harness_data_root());
    let project_name = project_resolver::resolve_name(&origin, &root)
        .map_err(|error| workflow_io(format!("resolve orphan cleanup project: {error}")))?;
    let layout = WorkingCopyLayout {
        working_copies_root: root,
        project_name,
        working_copy_id: identity.working_copy_id.clone(),
    };
    spawn_blocking(move || destroy_workspace_layout(&origin, &layout))
        .await
        .map_err(|error| workflow_io(format!("join remote orphan cleanup: {error}")))?
}

fn destroy_workspace_layout(origin: &Path, layout: &WorkingCopyLayout) -> Result<(), CliError> {
    if layout.workspace().exists() {
        WorktreeController::destroy(origin, layout)
            .map_err(|error| workflow_io(format!("destroy remote working copy: {error}")))?;
    }
    if layout.checkout_root().exists() {
        fs_err::remove_dir_all(layout.checkout_root())
            .map_err(|error| workflow_io(format!("remove remote working copy: {error}")))?;
    }
    Ok(())
}
