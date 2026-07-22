use base64::Engine as _;
use sha2::{Digest, Sha256};
use sqlx::{Sqlite, Transaction, query, query_as};

use super::remote_assignment_lease::require_assignment;
use super::remote_assignment_model::{canonical_time, concurrent, nonblank, to_i64};
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
    claim_controller_operation_trust_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteArtifactFetchRequest, RemoteArtifactFetchResponse,
    RemoteArtifactManifest, RemoteAssignmentWireState, RemoteAttemptBinding,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemoteArtifact {
    pub(crate) assignment_id: String,
    pub(crate) fencing_epoch: u64,
    pub(crate) lease_id: String,
    pub(crate) offer_request_sha256: String,
    pub(crate) authenticated_principal: String,
    pub(crate) artifact: RemoteArtifactEntry,
    pub(crate) content: Vec<u8>,
    pub(crate) stored_at: String,
}

impl TaskBoardRemoteArtifact {
    pub(crate) fn response(
        &self,
        request: &RemoteArtifactFetchRequest,
    ) -> Result<RemoteArtifactFetchResponse, CliError> {
        if !self.is_exact_fetch(request) {
            return Err(concurrent(
                "remote artifact does not match the exact fetch request",
            ));
        }
        Ok(RemoteArtifactFetchResponse {
            schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
            binding: request.binding.clone(),
            offer_request_sha256: request.offer_request_sha256.clone(),
            artifact: self.artifact.clone(),
            content_base64: base64::engine::general_purpose::STANDARD.encode(&self.content),
        })
    }

    fn is_exact_fetch(&self, request: &RemoteArtifactFetchRequest) -> bool {
        self.assignment_id == request.binding.assignment_id
            && self.fencing_epoch == request.binding.fencing_epoch
            && self.lease_id == request.lease_id
            && self.offer_request_sha256 == request.offer_request_sha256
            && self.artifact.relative_path == request.relative_path
            && self.artifact.sha256 == request.expected_sha256
    }
}

impl AsyncDaemonDb {
    pub(crate) async fn claim_task_board_remote_artifact_fetch_io_authority_fenced(
        &self,
        request: &RemoteArtifactFetchRequest,
        authenticated_principal: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<bool, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote artifact authority: {error}")))?;
        nonblank(
            authenticated_principal,
            "remote artifact authority principal",
        )?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote artifact I/O authority")
            .await?;
        let assignment =
            require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        let expected_artifact = manifest_entry(&assignment, request)?;
        require_artifact_assignment(
            &assignment,
            &request.binding,
            &request.lease_id,
            &request.offer_request_sha256,
            authenticated_principal,
            expected_artifact,
        )?;
        claim_controller_operation_trust_in_tx(
            &mut transaction,
            &assignment,
            TaskBoardRemoteOperationKind::FetchArtifact,
            &request.request_sha256,
            Some(trust),
        )
        .await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote artifact I/O authority: {error}")))?;
        Ok(true)
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn store_task_board_remote_artifact(
        &self,
        binding: &RemoteAttemptBinding,
        lease_id: &str,
        offer_request_sha256: &str,
        artifact: &RemoteArtifactEntry,
        content: &[u8],
        authenticated_principal: &str,
        stored_at: &str,
    ) -> Result<TaskBoardRemoteArtifact, CliError> {
        validate_artifact_input(
            binding,
            lease_id,
            offer_request_sha256,
            artifact,
            content,
            authenticated_principal,
            stored_at,
        )?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote artifact store")
            .await?;
        let assignment = require_assignment(&mut transaction, &binding.assignment_id).await?;
        require_artifact_assignment(
            &assignment,
            binding,
            lease_id,
            offer_request_sha256,
            authenticated_principal,
            artifact,
        )?;
        if let Some(existing) = load_artifact_in_tx(
            &mut transaction,
            &binding.assignment_id,
            binding.fencing_epoch,
            &artifact.relative_path,
        )
        .await?
        {
            if exact_artifact_replay(
                &existing,
                lease_id,
                offer_request_sha256,
                authenticated_principal,
                artifact,
                content,
            ) {
                transaction.commit().await.map_err(|error| {
                    db_error(format!("commit replayed remote artifact: {error}"))
                })?;
                return Ok(existing);
            }
            return Err(concurrent(
                "remote artifact path conflicts with immutable content evidence",
            ));
        }
        insert_artifact_in_tx(
            &mut transaction,
            binding,
            lease_id,
            offer_request_sha256,
            artifact,
            content,
            authenticated_principal,
            stored_at,
        )
        .await?;
        let stored = load_artifact_in_tx(
            &mut transaction,
            &binding.assignment_id,
            binding.fencing_epoch,
            &artifact.relative_path,
        )
        .await?
        .ok_or_else(|| db_error("persisted remote artifact disappeared"))?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote artifact: {error}")))?;
        Ok(stored)
    }

    pub(crate) async fn task_board_remote_artifact(
        &self,
        request: &RemoteArtifactFetchRequest,
        authenticated_principal: &str,
    ) -> Result<Option<TaskBoardRemoteArtifact>, CliError> {
        request
            .validate()
            .map_err(|error| db_error(format!("validate remote artifact fetch: {error}")))?;
        nonblank(authenticated_principal, "remote artifact fetch principal")?;
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin remote artifact fetch: {error}")))?;
        let assignment =
            require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        let expected_artifact = manifest_entry(&assignment, request)?.clone();
        require_artifact_assignment(
            &assignment,
            &request.binding,
            &request.lease_id,
            &request.offer_request_sha256,
            authenticated_principal,
            &expected_artifact,
        )?;
        let artifact = load_artifact_in_tx(
            &mut transaction,
            &request.binding.assignment_id,
            request.binding.fencing_epoch,
            &request.relative_path,
        )
        .await?;
        if artifact.as_ref().is_some_and(|stored| {
            stored.authenticated_principal != authenticated_principal
                || !stored.is_exact_fetch(request)
        }) {
            return Err(concurrent(
                "remote artifact fetch conflicts with immutable content evidence",
            ));
        }
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote artifact fetch: {error}")))?;
        Ok(artifact)
    }
}

#[allow(clippy::too_many_arguments)]
fn validate_artifact_input(
    binding: &RemoteAttemptBinding,
    lease_id: &str,
    offer_request_sha256: &str,
    artifact: &RemoteArtifactEntry,
    content: &[u8],
    principal: &str,
    stored_at: &str,
) -> Result<(), CliError> {
    binding
        .validate()
        .map_err(|error| db_error(format!("validate remote artifact binding: {error}")))?;
    nonblank(lease_id, "remote artifact lease")?;
    nonblank(principal, "remote artifact principal")?;
    canonical_time(stored_at, "remote artifact store time")?;
    validate_artifact_evidence(offer_request_sha256, artifact, content)
}

pub(super) fn validate_artifact_evidence(
    offer_request_sha256: &str,
    artifact: &RemoteArtifactEntry,
    content: &[u8],
) -> Result<(), CliError> {
    RemoteArtifactManifest {
        entries: vec![artifact.clone()],
    }
    .validate()
    .map_err(|error| db_error(format!("validate remote artifact entry: {error}")))?;
    let canonical_offer_digest = offer_request_sha256.len() == 64
        && offer_request_sha256
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte));
    if canonical_offer_digest
        && hex::encode(Sha256::digest(content)) == artifact.sha256
        && usize::try_from(artifact.size_bytes).ok() == Some(content.len())
    {
        Ok(())
    } else {
        Err(db_error(
            "remote artifact bytes do not match their immutable digest and size",
        ))
    }
}

pub(super) fn require_artifact_assignment(
    assignment: &super::TaskBoardRemoteAssignmentRecord,
    binding: &RemoteAttemptBinding,
    lease_id: &str,
    offer_request_sha256: &str,
    principal: &str,
    artifact: &RemoteArtifactEntry,
) -> Result<(), CliError> {
    let offer = assignment.require_offer()?;
    let exact = assignment.wire_state() == RemoteAssignmentWireState::Completed
        && offer.binding == *binding
        && offer.request_sha256 == offer_request_sha256
        && assignment.lease_id.as_deref() == Some(lease_id)
        && assignment.authenticated_principal.as_deref() == Some(principal)
        && assignment.status_response.as_ref().is_some_and(|status| {
            status
                .output_artifacts
                .entries
                .iter()
                .any(|entry| entry == artifact)
        });
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "remote artifact does not match durable terminal assignment evidence",
        ))
    }
}

pub(super) fn manifest_entry<'a>(
    assignment: &'a super::TaskBoardRemoteAssignmentRecord,
    request: &RemoteArtifactFetchRequest,
) -> Result<&'a RemoteArtifactEntry, CliError> {
    assignment
        .status_response
        .as_ref()
        .and_then(|status| {
            status.output_artifacts.entries.iter().find(|entry| {
                entry.relative_path == request.relative_path
                    && entry.sha256 == request.expected_sha256
            })
        })
        .ok_or_else(|| {
            concurrent("remote artifact request does not match the durable result manifest")
        })
}

#[derive(sqlx::FromRow)]
struct RemoteArtifactRow {
    assignment_id: String,
    fencing_epoch: i64,
    lease_id: String,
    offer_request_sha256: String,
    authenticated_principal: String,
    relative_path: String,
    sha256: String,
    size_bytes: i64,
    media_type: String,
    content: Vec<u8>,
    stored_at: String,
}

impl RemoteArtifactRow {
    fn into_artifact(self) -> Result<TaskBoardRemoteArtifact, CliError> {
        let fencing_epoch = u64::try_from(self.fencing_epoch)
            .ok()
            .filter(|value| *value > 0)
            .ok_or_else(|| db_error("remote artifact fencing epoch is invalid"))?;
        let size_bytes = u64::try_from(self.size_bytes)
            .map_err(|_| db_error("remote artifact size is invalid"))?;
        canonical_time(&self.stored_at, "remote artifact stored time")?;
        let artifact = RemoteArtifactEntry {
            relative_path: self.relative_path,
            sha256: self.sha256,
            size_bytes,
            media_type: self.media_type,
        };
        nonblank(&self.lease_id, "stored remote artifact lease")?;
        nonblank(
            &self.authenticated_principal,
            "stored remote artifact principal",
        )?;
        validate_artifact_evidence(&self.offer_request_sha256, &artifact, &self.content)?;
        Ok(TaskBoardRemoteArtifact {
            assignment_id: self.assignment_id,
            fencing_epoch,
            lease_id: self.lease_id,
            offer_request_sha256: self.offer_request_sha256,
            authenticated_principal: self.authenticated_principal,
            artifact,
            content: self.content,
            stored_at: self.stored_at,
        })
    }
}

pub(super) async fn load_artifact_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
    fencing_epoch: u64,
    relative_path: &str,
) -> Result<Option<TaskBoardRemoteArtifact>, CliError> {
    query_as::<_, RemoteArtifactRow>(
        "SELECT assignment_id, fencing_epoch, lease_id, offer_request_sha256,
                authenticated_principal, relative_path, sha256, size_bytes, media_type,
                content, stored_at
         FROM task_board_remote_artifacts
         WHERE assignment_id = ?1 AND fencing_epoch = ?2 AND relative_path = ?3",
    )
    .bind(assignment_id)
    .bind(to_i64(fencing_epoch, "artifact fencing epoch")?)
    .bind(relative_path)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load remote artifact: {error}")))?
    .map(RemoteArtifactRow::into_artifact)
    .transpose()
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn insert_artifact_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    binding: &RemoteAttemptBinding,
    lease_id: &str,
    offer_request_sha256: &str,
    artifact: &RemoteArtifactEntry,
    content: &[u8],
    authenticated_principal: &str,
    stored_at: &str,
) -> Result<(), CliError> {
    query(
        "INSERT INTO task_board_remote_artifacts (
           assignment_id, fencing_epoch, lease_id, offer_request_sha256,
           authenticated_principal, relative_path, sha256, size_bytes, media_type,
           content, stored_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
    )
    .bind(&binding.assignment_id)
    .bind(to_i64(binding.fencing_epoch, "artifact fencing epoch")?)
    .bind(lease_id)
    .bind(offer_request_sha256)
    .bind(authenticated_principal)
    .bind(&artifact.relative_path)
    .bind(&artifact.sha256)
    .bind(i64::try_from(artifact.size_bytes).map_err(|_| db_error("artifact is too large"))?)
    .bind(&artifact.media_type)
    .bind(content)
    .bind(stored_at)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("persist remote artifact: {error}")))
}

pub(super) fn exact_artifact_replay(
    stored: &TaskBoardRemoteArtifact,
    lease_id: &str,
    offer_request_sha256: &str,
    principal: &str,
    artifact: &RemoteArtifactEntry,
    content: &[u8],
) -> bool {
    stored.lease_id == lease_id
        && stored.offer_request_sha256 == offer_request_sha256
        && stored.authenticated_principal == principal
        && stored.artifact == *artifact
        && stored.content == content
}
