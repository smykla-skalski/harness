use std::path::{Path, PathBuf};

use tokio::task::spawn_blocking;

use super::{RemoteWorkerIdentity, concurrent, invalid_transition};
use crate::daemon::db::{AsyncDaemonDb, TaskBoardRemoteAssignmentRecord};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteOfferRequest, RemoteSourceMaterial,
};
use crate::errors::{CliError, CliErrorKind};
use crate::git::bundle::{GitBundleImportPlan, GitBundleWorktreeState};
use crate::git::source_bundle_import::GitSourceBundleImportPlan;

pub(super) async fn materialize_repository_snapshot(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    offer: &RemoteOfferRequest,
    repository: &Path,
) -> Result<Option<GitSourceBundleImportPlan>, CliError> {
    let RemoteSourceMaterial::RepositorySnapshotBundle {
        repository: repository_slug,
        revision,
        advertised_ref,
        bundle,
        ..
    } = &offer.source
    else {
        return Ok(None);
    };
    let stored = exact_materialized_request(db, record, offer).await?;
    let content = stored.validate().map_err(wire_error)?;
    let plan = GitSourceBundleImportPlan::new(
        repository,
        repository_slug.clone(),
        revision.clone(),
        advertised_ref.clone(),
        offer.request_sha256.clone(),
        bundle.sha256.clone(),
        bundle.size_bytes,
    )
    .map_err(git_error)?;
    let import = plan.clone();
    spawn_blocking(move || {
        import
            .verify_and_import_bytes(&content)
            .map_err(git_error)
    })
    .await
    .map_err(|error| CliErrorKind::workflow_io(format!("join remote source import: {error}")))??;
    Ok(Some(plan))
}

pub(super) async fn cleanup_repository_snapshot_import(
    plan: Option<GitSourceBundleImportPlan>,
) -> Result<(), CliError> {
    let Some(plan) = plan else {
        return Ok(());
    };
    spawn_blocking(move || plan.cleanup_import_ref().map_err(git_error))
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("join remote source import cleanup: {error}"))
        })?
}

pub(super) async fn apply_prior_phase_bundle(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    workspace: &Path,
) -> Result<(), CliError> {
    if matches!(
        &offer.source,
        RemoteSourceMaterial::RepositorySnapshotBundle { .. }
    ) {
        return Ok(());
    }
    let stored = exact_materialized_request(db, record, offer).await?;
    let RemoteSourceMaterial::PriorPhaseBundle {
        base_revision,
        revision,
        advertised_ref,
        bundle,
        ..
    } = &offer.source
    else {
        return Err(invalid_transition(
            "remote source bundle materialization requires bundle source",
        ));
    };
    let plan = SourceBundleImportPlan {
        workspace: workspace.to_path_buf(),
        branch_ref: format!("refs/heads/harness/{}", identity.session_id),
        base_revision: base_revision.clone(),
        result_revision: revision.clone(),
        advertised_ref: advertised_ref.clone(),
        import_ref: import_ref(offer, &bundle.sha256),
        content: stored.validate().map_err(wire_error)?,
    };
    spawn_blocking(move || plan.apply())
        .await
        .map_err(|error| CliErrorKind::workflow_io(format!("join remote source import: {error}")))?
}

pub(super) async fn cleanup_prior_phase_import_ref(
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
    workspace: Option<&Path>,
) -> Result<(), CliError> {
    let offer = record.require_offer()?;
    if let RemoteSourceMaterial::RepositorySnapshotBundle {
        repository,
        revision,
        advertised_ref,
        bundle,
        ..
    } = &offer.source
    {
        let checkout = record.executor_checkout_path.as_deref().ok_or_else(|| {
            concurrent("remote source cleanup has no frozen repository")
        })?;
        let plan = GitSourceBundleImportPlan::new(
            Path::new(checkout),
            repository.clone(),
            revision.clone(),
            advertised_ref.clone(),
            offer.request_sha256.clone(),
            bundle.sha256.clone(),
            bundle.size_bytes,
        )
        .map_err(git_error)?;
        return cleanup_repository_snapshot_import(Some(plan)).await;
    }
    let RemoteSourceMaterial::PriorPhaseBundle {
        base_revision,
        revision,
        advertised_ref,
        bundle,
        ..
    } = &offer.source else {
        return Ok(());
    };
    let repository = workspace
        .map(Path::to_path_buf)
        .or_else(|| record.executor_checkout_path.as_deref().map(PathBuf::from))
        .ok_or_else(|| concurrent("remote bundle cleanup has no frozen repository"))?;
    let branch_ref = format!("refs/heads/harness/{}", identity.session_id);
    let base_revision = base_revision.clone();
    let result_revision = revision.clone();
    let advertised_ref = advertised_ref.clone();
    let import_ref = import_ref(offer, &bundle.sha256);
    spawn_blocking(move || {
        GitBundleImportPlan::new(
            &repository,
            branch_ref,
            base_revision,
            result_revision,
            advertised_ref,
            import_ref,
        )
        .and_then(|plan| plan.cleanup_import_ref())
        .map_err(git_error)
    })
    .await
    .map_err(|error| CliErrorKind::workflow_io(format!("join remote bundle cleanup: {error}")))?
}

fn import_ref(offer: &RemoteOfferRequest, bundle_sha256: &str) -> String {
    format!(
        "refs/harness/task-board/imports/{}/{bundle_sha256}",
        offer.request_sha256
    )
}

async fn exact_materialized_request(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    offer: &RemoteOfferRequest,
) -> Result<crate::daemon::task_board_remote_transport::wire::RemoteSourceBundleUploadRequest, CliError>
{
    let stored = db
        .task_board_remote_source_bundle(record)
        .await?
        .ok_or_else(|| concurrent("remote source bundle disappeared before checkout"))?;
    if stored.offer != *offer {
        return Err(concurrent(
            "remote source bundle changed from its accepted offer",
        ));
    }
    stored.materialized_request()
}

struct SourceBundleImportPlan {
    workspace: PathBuf,
    branch_ref: String,
    base_revision: String,
    result_revision: String,
    advertised_ref: String,
    import_ref: String,
    content: Vec<u8>,
}

impl SourceBundleImportPlan {
    fn apply(self) -> Result<(), CliError> {
        let plan = GitBundleImportPlan::new(
            &self.workspace,
            self.branch_ref,
            self.base_revision,
            self.result_revision,
            self.advertised_ref,
            self.import_ref,
        )
        .map_err(git_error)?;
        plan.verify_and_import_bytes(&self.content)
            .map_err(git_error)?;
        for _ in 0..3 {
            if plan.state().map_err(git_error)? == GitBundleWorktreeState::AttachedResult {
                break;
            }
            plan.advance_one().map_err(git_error)?;
        }
        plan.require_applied().map_err(git_error)?;
        Ok(())
    }
}

fn git_error(error: crate::git::GitError) -> CliError {
    CliErrorKind::workflow_io(format!("apply remote source bundle: {error}")).into()
}

fn wire_error(error: impl std::fmt::Display) -> CliError {
    CliErrorKind::workflow_io(format!("materialize remote source bundle: {error}")).into()
}
