use sha2::{Digest as _, Sha256};
use sqlx::query_as;

use super::remote_artifacts::validate_artifact_evidence;
use super::remote_assignment_model::concurrent;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactEntry, RemoteSourceBundleUploadRequest,
};
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionPhase,
    TaskBoardImplementationResult, TaskBoardWorkflowExecutionRecord,
};

const IMPLEMENTATION_BUNDLE_PATH: &str = "result/implementation.bundle";
const IMPLEMENTATION_BUNDLE_MEDIA_TYPE: &str = "application/x-git-bundle";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRemotePriorPhaseBundle {
    pub(crate) origin_assignment_id: String,
    pub(crate) origin_fencing_epoch: u64,
    pub(crate) repository: String,
    pub(crate) base_revision: String,
    pub(crate) result_revision: String,
    pub(crate) artifact: RemoteArtifactEntry,
    pub(crate) content: Vec<u8>,
}

impl TaskBoardRemotePriorPhaseBundle {
    pub(crate) fn upload_request(
        &self,
        offer: crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
    ) -> Result<RemoteSourceBundleUploadRequest, CliError> {
        RemoteSourceBundleUploadRequest::seal(offer, &self.content)
            .map_err(|error| db_error(format!("seal prior-phase source upload: {error}")))
    }
}

impl AsyncDaemonDb {
    pub(crate) async fn task_board_remote_prior_phase_bundle(
        &self,
        execution: &TaskBoardWorkflowExecutionRecord,
        phase: TaskBoardExecutionPhase,
    ) -> Result<Option<TaskBoardRemotePriorPhaseBundle>, CliError> {
        let identity = prior_implementation_identity(execution, phase)?;
        let rows = query_as::<_, PriorBundleRow>(PriorBundleRow::SELECT)
            .bind(&execution.execution_id)
            .bind(&identity.action_key)
            .bind(i64::from(identity.attempt))
            .bind(&identity.idempotency_key)
            .bind(&identity.result.base_head_revision)
            .bind(&identity.result.head_revision)
            .fetch_all(self.pool())
            .await
            .map_err(|error| db_error(format!("load adopted prior-phase bundle: {error}")))?;
        let mut bundles = rows
            .into_iter()
            .map(|row| row.into_bundle(&identity))
            .collect::<Result<Vec<_>, _>>()?;
        bundles.extend(
            self.task_board_materialized_prior_phase_bundles(&identity)
                .await?,
        );
        consistent_bundle(bundles)
    }

    async fn task_board_materialized_prior_phase_bundles(
        &self,
        identity: &PriorImplementationIdentity,
    ) -> Result<Vec<TaskBoardRemotePriorPhaseBundle>, CliError> {
        let rows = query_as::<_, MaterializedPriorBundleRow>(MaterializedPriorBundleRow::SELECT)
            .bind(&identity.execution_id)
            .bind(&identity.result.base_head_revision)
            .bind(&identity.result.head_revision)
            .fetch_all(self.pool())
            .await
            .map_err(|error| db_error(format!("load materialized prior-phase bundle: {error}")))?;
        rows.into_iter()
            .map(|row| row.into_bundle(identity))
            .collect()
    }
}

struct PriorImplementationIdentity {
    execution_id: String,
    action_key: String,
    attempt: u32,
    idempotency_key: String,
    result: TaskBoardImplementationResult,
}

fn prior_implementation_identity(
    execution: &TaskBoardWorkflowExecutionRecord,
    phase: TaskBoardExecutionPhase,
) -> Result<PriorImplementationIdentity, CliError> {
    let cycle = match phase {
        TaskBoardExecutionPhase::Implementation => {
            execution.artifacts.current_revision_cycle.checked_sub(1)
        }
        TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate => {
            Some(execution.artifacts.current_revision_cycle)
        }
        _ => None,
    }
    .ok_or_else(|| concurrent("remote phase has no prior implementation cycle"))?;
    let matches = execution.attempts.iter().filter_map(|attempt| {
        let Some(TaskBoardAttemptResultArtifact::Implementation(result)) =
            attempt.artifact.as_ref()
        else {
            return None;
        };
        (result.revision_cycle == cycle).then_some((attempt, result))
    });
    let collected = matches.collect::<Vec<_>>();
    let [(attempt, result)] = collected.as_slice() else {
        return Err(concurrent(
            "remote phase does not have one exact prior implementation",
        ));
    };
    if attempt.state != TaskBoardAttemptState::Completed {
        return Err(concurrent(
            "remote prior implementation attempt is not completed",
        ));
    }
    Ok(PriorImplementationIdentity {
        execution_id: execution.execution_id.clone(),
        action_key: attempt.action_key.clone(),
        attempt: attempt.attempt,
        idempotency_key: attempt.idempotency_key.clone(),
        result: (**result).clone(),
    })
}

#[derive(Clone, sqlx::FromRow)]
struct PriorBundleRow {
    assignment_id: String,
    fencing_epoch: i64,
    execution_id: String,
    action_key: String,
    attempt: i64,
    idempotency_key: String,
    offer_request_sha256: String,
    repository: String,
    base_revision: String,
    result_revision: String,
    advertised_ref: String,
    bundle_sha256: String,
    relative_path: String,
    sha256: String,
    size_bytes: i64,
    media_type: String,
    content: Vec<u8>,
}

#[derive(sqlx::FromRow)]
struct MaterializedPriorBundleRow {
    assignment_id: String,
    fencing_epoch: i64,
    offer_json: String,
    base_revision: String,
    result_revision: String,
    advertised_ref: String,
    relative_path: String,
    sha256: String,
    size_bytes: i64,
    media_type: String,
    content: Vec<u8>,
}

impl MaterializedPriorBundleRow {
    const SELECT: &'static str = "SELECT assignment_id, fencing_epoch, offer_json,
        base_revision, result_revision, advertised_ref, relative_path, sha256,
        size_bytes, media_type, content
        FROM task_board_remote_source_bundles
        WHERE execution_id = ?1 AND base_revision = ?2 AND result_revision = ?3
          AND content_pruned_at IS NULL AND length(content) = size_bytes
          AND json_extract(offer_json, '$.source.kind') = 'prior_phase_bundle'
        ORDER BY assignment_id, fencing_epoch";

    fn into_bundle(
        self,
        expected: &PriorImplementationIdentity,
    ) -> Result<TaskBoardRemotePriorPhaseBundle, CliError> {
        let offer = serde_json::from_str::<
            crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest,
        >(&self.offer_json)
        .map_err(|error| db_error(format!("decode materialized prior-phase offer: {error}")))?;
        offer.validate().map_err(|error| {
            db_error(format!("validate materialized prior-phase offer: {error}"))
        })?;
        let crate::daemon::task_board_remote_transport::wire::RemoteSourceMaterial::PriorPhaseBundle {
            repository,
            base_revision,
            revision,
            advertised_ref,
            bundle,
            ..
        } = offer.source
        else {
            return Err(concurrent("materialized source is not a prior-phase bundle"));
        };
        let fencing_epoch = u64::try_from(self.fencing_epoch)
            .ok()
            .filter(|epoch| *epoch > 0)
            .ok_or_else(|| db_error("materialized source fencing epoch is invalid"))?;
        let size_bytes = u64::try_from(self.size_bytes)
            .map_err(|_| db_error("materialized source size is invalid"))?;
        let artifact = RemoteArtifactEntry {
            relative_path: self.relative_path,
            sha256: self.sha256,
            size_bytes,
            media_type: self.media_type,
        };
        let exact = base_revision == expected.result.base_head_revision
            && revision == expected.result.head_revision
            && self.base_revision == base_revision
            && self.result_revision == revision
            && self.advertised_ref == advertised_ref
            && bundle == artifact
            && advertised_ref == format!("refs/harness/task-board/results/{revision}")
            && artifact.relative_path == IMPLEMENTATION_BUNDLE_PATH
            && artifact.media_type == IMPLEMENTATION_BUNDLE_MEDIA_TYPE
            && hex::encode(Sha256::digest(&self.content)) == artifact.sha256
            && usize::try_from(artifact.size_bytes).ok() == Some(self.content.len());
        if !exact {
            return Err(concurrent(
                "materialized prior-phase source contradicts implementation evidence",
            ));
        }
        Ok(TaskBoardRemotePriorPhaseBundle {
            origin_assignment_id: self.assignment_id,
            origin_fencing_epoch: fencing_epoch,
            repository,
            base_revision,
            result_revision: revision,
            artifact,
            content: self.content,
        })
    }
}

fn same_bundle(
    left: &TaskBoardRemotePriorPhaseBundle,
    right: &TaskBoardRemotePriorPhaseBundle,
) -> bool {
    left.repository == right.repository
        && left.base_revision == right.base_revision
        && left.result_revision == right.result_revision
        && left.artifact == right.artifact
        && left.content == right.content
}

pub(super) fn consistent_bundle(
    mut bundles: Vec<TaskBoardRemotePriorPhaseBundle>,
) -> Result<Option<TaskBoardRemotePriorPhaseBundle>, CliError> {
    let Some(first) = bundles.pop() else {
        return Ok(None);
    };
    if bundles
        .iter()
        .any(|candidate| !same_bundle(candidate, &first))
    {
        return Err(concurrent(
            "prior-phase source copies disagree on exact portable content",
        ));
    }
    Ok(Some(first))
}

impl PriorBundleRow {
    const SELECT: &'static str = "SELECT i.assignment_id, i.fencing_epoch,
        i.execution_id, i.action_key, i.attempt, i.idempotency_key,
        i.offer_request_sha256,
        json_extract(origin.request_json, '$.source.repository') AS repository,
        i.base_revision, i.result_revision,
        i.advertised_ref, i.bundle_sha256, a.relative_path, a.sha256,
        a.size_bytes, a.media_type, a.content
        FROM task_board_remote_result_imports i
        JOIN task_board_remote_artifacts a
          ON a.assignment_id = i.assignment_id
         AND a.fencing_epoch = i.fencing_epoch
         AND a.relative_path = 'result/implementation.bundle'
        JOIN task_board_remote_assignments origin
          ON origin.assignment_id = i.assignment_id
         AND origin.fencing_epoch = i.fencing_epoch
        WHERE i.execution_id = ?1 AND i.action_key = ?2 AND i.attempt = ?3
          AND i.idempotency_key = ?4 AND i.base_revision = ?5
          AND i.result_revision = ?6 AND i.state = 'adopted'
          AND i.bundle_sha256 = a.sha256
        ORDER BY i.assignment_id, i.fencing_epoch";

    fn into_bundle(
        self,
        expected: &PriorImplementationIdentity,
    ) -> Result<TaskBoardRemotePriorPhaseBundle, CliError> {
        let fencing_epoch = u64::try_from(self.fencing_epoch)
            .ok()
            .filter(|epoch| *epoch > 0)
            .ok_or_else(|| db_error("prior-phase bundle fencing epoch is invalid"))?;
        let attempt = u32::try_from(self.attempt)
            .ok()
            .filter(|attempt| *attempt > 0)
            .ok_or_else(|| db_error("prior-phase bundle attempt is invalid"))?;
        let size_bytes = u64::try_from(self.size_bytes)
            .map_err(|_| db_error("prior-phase bundle size is invalid"))?;
        let artifact = RemoteArtifactEntry {
            relative_path: self.relative_path,
            sha256: self.sha256,
            size_bytes,
            media_type: self.media_type,
        };
        validate_artifact_evidence(&self.offer_request_sha256, &artifact, &self.content)?;
        let advertised = format!(
            "refs/harness/task-board/results/{}",
            expected.result.head_revision
        );
        let exact = self.action_key == expected.action_key
            && self.execution_id == expected.execution_id
            && attempt == expected.attempt
            && self.idempotency_key == expected.idempotency_key
            && !self.repository.trim().is_empty()
            && self.base_revision == expected.result.base_head_revision
            && self.result_revision == expected.result.head_revision
            && self.advertised_ref == advertised
            && self.bundle_sha256 == artifact.sha256
            && artifact.relative_path == IMPLEMENTATION_BUNDLE_PATH
            && artifact.media_type == IMPLEMENTATION_BUNDLE_MEDIA_TYPE
            && hex::encode(Sha256::digest(&self.content)) == artifact.sha256;
        if !exact {
            return Err(concurrent(
                "adopted prior-phase bundle contradicts implementation evidence",
            ));
        }
        Ok(TaskBoardRemotePriorPhaseBundle {
            origin_assignment_id: self.assignment_id,
            origin_fencing_epoch: fencing_epoch,
            repository: self.repository,
            base_revision: self.base_revision,
            result_revision: self.result_revision,
            artifact,
            content: self.content,
        })
    }
}
