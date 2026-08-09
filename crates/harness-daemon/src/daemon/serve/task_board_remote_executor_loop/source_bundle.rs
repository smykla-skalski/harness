#[cfg(test)]
use std::collections::HashMap;
use std::fmt::Display;
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::{Mutex, OnceLock};

use tokio::task::spawn_blocking;

use super::{RemoteWorkerIdentity, concurrent, invalid_transition};
use crate::daemon::db::TaskBoardRemoteAssignmentRecord;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::git::GitError;
use crate::git::bundle::{GitBundleImportPlan, GitBundleWorktreeState};
use crate::git::source_bundle_import::GitSourceBundleImportPlan;
use crate::task_board::remote_wire::wire::RemoteSourceBundleUploadRequest;
use crate::task_board::remote_wire::wire::{RemoteOfferRequest, RemoteSourceMaterial};
use harness_kernel::errors::{CliError, CliErrorKind};

pub(super) async fn materialize_repository_snapshot(
    db: &AsyncDaemonDbHandle,
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
    let content = stored.validate().map_err(|error| wire_error(&error))?;
    let plan = GitSourceBundleImportPlan::new(
        repository,
        repository_slug.clone(),
        revision.clone(),
        advertised_ref.clone(),
        &offer.request_sha256,
        bundle.sha256.clone(),
        bundle.size_bytes,
    )
    .map_err(|error| git_error(&error))?;
    let import = plan.clone();
    spawn_blocking(move || {
        import
            .verify_and_import_bytes(&content)
            .map_err(|error| git_error(&error))
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
    spawn_blocking(move || plan.cleanup_import_ref().map_err(|error| git_error(&error)))
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("join remote source import cleanup: {error}"))
        })?
}

pub(super) async fn apply_prior_phase_bundle(
    db: &AsyncDaemonDbHandle,
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
    #[cfg(test)]
    record_prior_phase_application(record);
    let import = prior_phase_import_plan(offer, identity, workspace).await?;
    let probe = import.clone();
    let already_applied = spawn_blocking(move || probe.require_applied().is_ok())
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("join remote source state check: {error}"))
        })?;
    if already_applied {
        return Ok(());
    }
    let stored = exact_materialized_request(db, record, offer).await?;
    let plan = SourceBundleImportPlan {
        import,
        content: stored.validate().map_err(|error| wire_error(&error))?,
    };
    spawn_blocking(move || plan.apply())
        .await
        .map_err(|error| CliErrorKind::workflow_io(format!("join remote source import: {error}")))?
}

pub(super) async fn require_prior_phase_bundle_applied(
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    workspace: &Path,
) -> Result<(), CliError> {
    let import = prior_phase_import_plan(offer, identity, workspace).await?;
    spawn_blocking(move || {
        import
            .require_applied()
            .map(|_| ())
            .map_err(|error| git_error(&error))
    })
    .await
    .map_err(|error| CliErrorKind::workflow_io(format!("join remote source audit: {error}")))?
}

async fn prior_phase_import_plan(
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    workspace: &Path,
) -> Result<GitBundleImportPlan, CliError> {
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
    let workspace = workspace.to_path_buf();
    let branch_ref = executor_branch_ref(offer, identity);
    let base_revision = base_revision.clone();
    let result_revision = revision.clone();
    let advertised_ref = advertised_ref.clone();
    let import_ref = import_ref(offer, &bundle.sha256);
    spawn_blocking(move || {
        GitBundleImportPlan::new(
            &workspace,
            branch_ref,
            base_revision,
            result_revision,
            advertised_ref,
            import_ref,
        )
        .map_err(|error| git_error(&error))
    })
    .await
    .map_err(|error| CliErrorKind::workflow_io(format!("join remote source plan: {error}")))?
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
        let checkout = record
            .executor_checkout_path
            .as_deref()
            .ok_or_else(|| concurrent("remote source cleanup has no frozen repository"))?;
        let plan = GitSourceBundleImportPlan::new(
            Path::new(checkout),
            repository.clone(),
            revision.clone(),
            advertised_ref.clone(),
            &offer.request_sha256,
            bundle.sha256.clone(),
            bundle.size_bytes,
        )
        .map_err(|error| git_error(&error))?;
        return cleanup_repository_snapshot_import(Some(plan)).await;
    }
    let RemoteSourceMaterial::PriorPhaseBundle {
        base_revision,
        revision,
        advertised_ref,
        bundle,
        ..
    } = &offer.source
    else {
        return Ok(());
    };
    let repository = workspace
        .map(Path::to_path_buf)
        .or_else(|| record.executor_checkout_path.as_deref().map(PathBuf::from))
        .ok_or_else(|| concurrent("remote bundle cleanup has no frozen repository"))?;
    let branch_ref = executor_branch_ref(offer, identity);
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
        .map_err(|error| git_error(&error))
    })
    .await
    .map_err(|error| CliErrorKind::workflow_io(format!("join remote bundle cleanup: {error}")))?
}

fn executor_branch_ref(offer: &RemoteOfferRequest, identity: &RemoteWorkerIdentity) -> String {
    let owner_id = if offer.work_owner.is_some() {
        &identity.working_copy_id
    } else {
        &identity.session_id
    };
    format!("refs/heads/harness/{owner_id}")
}

fn import_ref(offer: &RemoteOfferRequest, bundle_sha256: &str) -> String {
    format!(
        "refs/harness/task-board/imports/{}/{bundle_sha256}",
        offer.request_sha256
    )
}

async fn exact_materialized_request(
    db: &AsyncDaemonDbHandle,
    record: &TaskBoardRemoteAssignmentRecord,
    offer: &RemoteOfferRequest,
) -> Result<RemoteSourceBundleUploadRequest, CliError> {
    #[cfg(test)]
    record_materialized_request_read(record);
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
    import: GitBundleImportPlan,
    content: Vec<u8>,
}

impl SourceBundleImportPlan {
    fn apply(self) -> Result<(), CliError> {
        self.import
            .verify_and_import_bytes(&self.content)
            .map_err(|error| git_error(&error))?;
        for _ in 0..3 {
            if self.import.state().map_err(|error| git_error(&error))?
                == GitBundleWorktreeState::AttachedResult
            {
                break;
            }
            self.import
                .advance_one()
                .map_err(|error| git_error(&error))?;
        }
        self.import
            .require_applied()
            .map_err(|error| git_error(&error))?;
        Ok(())
    }
}

#[cfg(test)]
pub(super) fn materialized_request_read_count(record: &TaskBoardRemoteAssignmentRecord) -> usize {
    materialized_request_reads()
        .lock()
        .expect("lock remote source read counts")
        .get(&materialized_request_key(record))
        .copied()
        .unwrap_or_default()
}

#[cfg(test)]
pub(super) fn prior_phase_application_count(record: &TaskBoardRemoteAssignmentRecord) -> usize {
    prior_phase_applications()
        .lock()
        .expect("lock prior-phase application counts")
        .get(&materialized_request_key(record))
        .copied()
        .unwrap_or_default()
}

#[cfg(test)]
fn record_materialized_request_read(record: &TaskBoardRemoteAssignmentRecord) {
    let mut reads = materialized_request_reads()
        .lock()
        .expect("lock remote source read counts");
    *reads.entry(materialized_request_key(record)).or_default() += 1;
}

#[cfg(test)]
fn record_prior_phase_application(record: &TaskBoardRemoteAssignmentRecord) {
    let mut applications = prior_phase_applications()
        .lock()
        .expect("lock prior-phase application counts");
    *applications
        .entry(materialized_request_key(record))
        .or_default() += 1;
}

#[cfg(test)]
fn materialized_request_key(record: &TaskBoardRemoteAssignmentRecord) -> String {
    format!(
        "{}:{}",
        record.assignment_id,
        record.executor_checkout_path.as_deref().unwrap_or_default()
    )
}

#[cfg(test)]
fn materialized_request_reads() -> &'static Mutex<HashMap<String, usize>> {
    static READS: OnceLock<Mutex<HashMap<String, usize>>> = OnceLock::new();
    READS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[cfg(test)]
fn prior_phase_applications() -> &'static Mutex<HashMap<String, usize>> {
    static APPLICATIONS: OnceLock<Mutex<HashMap<String, usize>>> = OnceLock::new();
    APPLICATIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn git_error(error: &GitError) -> CliError {
    CliErrorKind::workflow_io(format!("apply remote source bundle: {error}")).into()
}

fn wire_error(error: &impl Display) -> CliError {
    CliErrorKind::workflow_io(format!("materialize remote source bundle: {error}")).into()
}
