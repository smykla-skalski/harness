#[cfg(test)]
use std::collections::HashMap;
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::{Arc, Mutex, OnceLock};

use sqlx::query_scalar;
#[cfg(test)]
use tokio::sync::Barrier;
use tokio::task::spawn_blocking;

use super::source_bundle::{cleanup_repository_snapshot_import, materialize_repository_snapshot};
use super::{RemoteWorkerIdentity, concurrent, invalid_transition};
use crate::daemon::db::{AsyncDaemonDb, TaskBoardRemoteAssignmentRecord, db_error};
use crate::daemon::protocol::SessionStartRequest;
use crate::daemon::service::start_session_direct_async;
use crate::daemon::task_board_remote_transport::wire::{RemoteOfferRequest, RemoteSourceMaterial};
use crate::errors::{CliError, CliErrorKind};
use crate::git::GitRepository;
use crate::task_board::{
    TaskBoardExecutionPhase, TaskBoardOrchestratorSettings, validate_local_execution_host_config,
};

use super::source_bundle::apply_prior_phase_bundle;

pub(super) async fn prepare_remote_workspace(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    starts_worker: bool,
) -> Result<PathBuf, CliError> {
    if starts_worker && !executor_settings_match(db, record, offer).await? {
        return Err(concurrent(
            "remote executor settings changed before worker start",
        ));
    }
    let require_source_head =
        starts_worker || offer.binding.phase != TaskBoardExecutionPhase::Implementation;
    let revision = initial_source_revision(offer)?;
    let repository_source = matches!(offer.source, RemoteSourceMaterial::Repository { .. });
    let workspace = ensure_remote_session(
        db,
        record,
        identity,
        revision,
        starts_worker,
        require_source_head && repository_source,
    )
    .await?;
    if require_source_head && !repository_source {
        apply_prior_phase_bundle(db, record, offer, identity, &workspace).await?;
    }
    if starts_worker && !executor_settings_match(db, record, offer).await? {
        return Err(concurrent(
            "remote executor settings changed while preparing the checkout",
        ));
    }
    Ok(workspace)
}

pub(super) async fn ensure_remote_session(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &RemoteWorkerIdentity,
    revision: &str,
    allow_create: bool,
    require_source_head: bool,
) -> Result<PathBuf, CliError> {
    let origin = PathBuf::from(record.executor_checkout_path.as_deref().ok_or_else(|| {
        invalid_transition("remote executor assignment has no frozen checkout path")
    })?);
    let offer = record.require_offer()?;
    let snapshot_import = materialize_repository_snapshot(db, record, offer, &origin).await?;
    let require_source_head = require_source_head
        || matches!(
            &offer.source,
            RemoteSourceMaterial::RepositorySnapshotBundle { .. }
        );
    if require_source_head {
        verify_repository_revision(origin.clone(), revision.to_string()).await?;
    }
    let workspace = if let Some(resolved) = db.resolve_session(&identity.session_id).await? {
        validate_remote_session(
            &resolved.state,
            &origin,
            revision,
            &identity.session_id,
            require_source_head,
        )
        .await?;
        resolved.state.worktree_path
    } else if !allow_create {
        cleanup_repository_snapshot_import(snapshot_import).await?;
        return Err(concurrent(
            "started remote assignment has no durable executor session",
        ));
    } else {
        #[cfg(test)]
        super::test_seam::record_provision();
        let session = start_session_direct_async(
            &SessionStartRequest {
                title: format!("Remote Task Board {}", record.execution_id),
                context: format!(
                    "Remote Task Board assignment {} fencing epoch {}",
                    record.assignment_id, record.fencing_epoch
                ),
                session_id: Some(identity.session_id.clone()),
                project_dir: origin.to_string_lossy().into_owned(),
                policy_preset: None,
                base_ref: Some(revision.to_string()),
            },
            db,
        )
        .await?;
        #[cfg(test)]
        wait_after_remote_session_creation(record).await;
        validate_remote_session(
            &session,
            &origin,
            revision,
            &identity.session_id,
            require_source_head,
        )
        .await?;
        session.worktree_path
    };
    cleanup_repository_snapshot_import(snapshot_import).await?;
    Ok(workspace)
}

#[cfg(test)]
pub(super) struct RemoteSessionCreationBarrier {
    entered: Barrier,
    released: Barrier,
}

#[cfg(test)]
impl RemoteSessionCreationBarrier {
    pub(super) async fn wait_until_entered(&self) {
        self.entered.wait().await;
    }

    pub(super) async fn release(&self) {
        self.released.wait().await;
    }
}

#[cfg(test)]
pub(super) fn install_remote_session_creation_barrier(
    start_authority_sha256: &str,
) -> Arc<RemoteSessionCreationBarrier> {
    let barrier = Arc::new(RemoteSessionCreationBarrier {
        entered: Barrier::new(2),
        released: Barrier::new(2),
    });
    session_creation_barriers()
        .lock()
        .expect("lock remote session creation barriers")
        .insert(start_authority_sha256.into(), barrier.clone());
    barrier
}

#[cfg(test)]
async fn wait_after_remote_session_creation(record: &TaskBoardRemoteAssignmentRecord) {
    let Some(authority_sha256) = record.executor_start_authority_sha256.as_deref() else {
        return;
    };
    let barrier = session_creation_barriers()
        .lock()
        .expect("lock remote session creation barriers")
        .remove(authority_sha256);
    if let Some(barrier) = barrier {
        barrier.entered.wait().await;
        barrier.released.wait().await;
    }
}

#[cfg(test)]
fn session_creation_barriers() -> &'static Mutex<HashMap<String, Arc<RemoteSessionCreationBarrier>>>
{
    static BARRIERS: OnceLock<Mutex<HashMap<String, Arc<RemoteSessionCreationBarrier>>>> =
        OnceLock::new();
    BARRIERS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(super) async fn executor_settings_match(
    db: &AsyncDaemonDb,
    record: &TaskBoardRemoteAssignmentRecord,
    offer: &RemoteOfferRequest,
) -> Result<bool, CliError> {
    let Some(expected_revision) = record.executor_configuration_revision else {
        return Ok(false);
    };
    let Some(expected_checkout) = record.executor_checkout_path.as_deref() else {
        return Ok(false);
    };
    let (settings_json, revision) = sqlx::query_as::<_, (String, i64)>(
        "SELECT settings_json, revision FROM task_board_orchestrator_settings WHERE singleton = 1",
    )
    .fetch_one(db.pool())
    .await
    .map_err(|error| db_error(format!("load remote executor settings: {error}")))?;
    let settings = serde_json::from_str::<TaskBoardOrchestratorSettings>(&settings_json)
        .map_err(|error| db_error(format!("decode remote executor settings: {error}")))?;
    validate_local_execution_host_config(&settings.local_execution_host)?;
    let host = &settings.local_execution_host;
    let source_repository = offer.source.repository();
    let revision_matches = u64::try_from(revision).ok() == Some(expected_revision);
    let configured = host.enabled
        && host.host_id == record.host_id
        && host
            .runtimes
            .iter()
            .any(|runtime| runtime == &offer.launch.runtime)
        && host.repositories.iter().any(|repository| {
            repository.repository == source_repository
                && repository.checkout_path == expected_checkout
        });
    let provisioned = query_scalar::<_, bool>(
        "SELECT EXISTS(
           SELECT 1 FROM task_board_execution_hosts
           WHERE host_id = ?1 AND host_role = 'executor_self'
             AND configuration_revision = ?2 AND enabled = 1
         )",
    )
    .bind(&record.host_id)
    .bind(revision)
    .fetch_one(db.pool())
    .await
    .map_err(|error| db_error(format!("verify remote executor host identity: {error}")))?;
    Ok(revision_matches && configured && provisioned)
}

pub(super) fn initial_source_revision(offer: &RemoteOfferRequest) -> Result<&str, CliError> {
    offer
        .validate()
        .map_err(|error| invalid_transition(format!("invalid sealed remote offer: {error}")))?;
    match &offer.source {
        RemoteSourceMaterial::Repository { revision, .. }
        | RemoteSourceMaterial::RepositorySnapshotBundle { revision, .. } => Ok(revision),
        RemoteSourceMaterial::PriorPhaseBundle { base_revision, .. } => Ok(base_revision),
    }
}

async fn verify_repository_revision(origin: PathBuf, revision: String) -> Result<(), CliError> {
    spawn_blocking(move || {
        let repository = GitRepository::discover(&origin).map_err(|error| git_error(&error))?;
        let resolved = repository
            .resolve_revision_to_commit(&revision)
            .map_err(|error| git_error(&error))?;
        if resolved == revision {
            Ok(())
        } else {
            Err(invalid_transition(
                "remote source revision did not resolve to its sealed object identity",
            ))
        }
    })
    .await
    .map_err(|error| CliErrorKind::workflow_io(format!("join remote source check: {error}")))?
}

async fn validate_remote_session(
    session: &crate::session::types::SessionState,
    origin: &Path,
    revision: &str,
    session_id: &str,
    require_source_head: bool,
) -> Result<(), CliError> {
    let expected_origin = origin.to_path_buf();
    let actual_origin = session.origin_path.clone();
    let worktree = session.worktree_path.clone();
    let revision = revision.to_string();
    let expected_branch = format!("harness/{session_id}");
    let actual_branch = session.branch_ref.clone();
    spawn_blocking(move || {
        let expected_origin = expected_origin
            .canonicalize()
            .map_err(|error| io_error(&error))?;
        let actual_origin = actual_origin
            .canonicalize()
            .map_err(|error| io_error(&error))?;
        if expected_origin != actual_origin
            || worktree == expected_origin
            || actual_branch != expected_branch
        {
            return Err(concurrent("remote executor session identity mismatched"));
        }
        validate_remote_worktree_head(&worktree, &revision, require_source_head)
    })
    .await
    .map_err(|error| CliErrorKind::workflow_io(format!("join remote session check: {error}")))?
}

pub(super) fn validate_remote_worktree_head(
    worktree: &Path,
    revision: &str,
    require_source_head: bool,
) -> Result<(), CliError> {
    let repository = GitRepository::discover(worktree).map_err(|error| git_error(&error))?;
    let head = repository
        .resolve_revision_to_commit("HEAD")
        .map_err(|error| git_error(&error))?;
    if !require_source_head || head == revision {
        Ok(())
    } else {
        Err(concurrent(
            "remote executor worktree head drifted before start",
        ))
    }
}

fn git_error(error: &crate::git::GitError) -> CliError {
    CliErrorKind::workflow_io(format!("verify remote executor Git source: {error}")).into()
}

fn io_error(error: &std::io::Error) -> CliError {
    CliErrorKind::workflow_io(format!("verify remote executor path: {error}")).into()
}
