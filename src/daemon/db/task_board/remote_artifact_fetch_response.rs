use super::remote_artifacts::{
    TaskBoardRemoteArtifact, TaskBoardRemoteArtifactStoreInput, exact_artifact_replay,
    insert_artifact_in_tx, load_artifact_in_tx, manifest_entry, require_artifact_assignment,
    validate_artifact_evidence,
};
use super::remote_assignment_lease::require_assignment;
use super::remote_assignment_model::{canonical_time, concurrent, nonblank};
use super::remote_operation_trust::{
    TaskBoardRemoteOperationKind, consume_controller_operation_trust_in_tx,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteArtifactFetchRequest, RemoteArtifactFetchResponse,
};

impl AsyncDaemonDb {
    /// Atomically adopts authenticated artifact bytes and consumes the exact
    /// current host-trust token that authorized their network fetch.
    pub(crate) async fn record_task_board_remote_artifact_fetch_response(
        &self,
        request: &RemoteArtifactFetchRequest,
        response: &RemoteArtifactFetchResponse,
        authenticated_principal: &str,
        stored_at: &str,
    ) -> Result<TaskBoardRemoteArtifact, CliError> {
        validate_response_input(request, authenticated_principal, stored_at)?;
        let content = response.validate(request).map_err(|error| {
            db_error(format!("validate remote artifact fetch response: {error}"))
        })?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote artifact fetch response")
            .await?;
        let assignment =
            require_assignment(&mut transaction, &request.binding.assignment_id).await?;
        let artifact = manifest_entry(&assignment, request)?;
        if artifact != &response.artifact {
            return Err(concurrent(
                "remote artifact response changed its durable manifest entry",
            ));
        }
        require_artifact_assignment(
            &assignment,
            &request.binding,
            &request.lease_id,
            &request.offer_request_sha256,
            authenticated_principal,
            artifact,
        )?;
        validate_artifact_evidence(&request.offer_request_sha256, artifact, &content)?;
        let input = TaskBoardRemoteArtifactStoreInput {
            binding: &request.binding,
            lease_id: &request.lease_id,
            offer_request_sha256: &request.offer_request_sha256,
            artifact,
            content: &content,
            authenticated_principal,
            stored_at,
        };
        let existing = load_artifact_in_tx(
            &mut transaction,
            &request.binding.assignment_id,
            request.binding.fencing_epoch,
            &request.relative_path,
        )
        .await?;
        if existing
            .as_ref()
            .is_some_and(|stored| !exact_artifact_replay(stored, &input))
        {
            return Err(concurrent(
                "remote artifact path conflicts with immutable content evidence",
            ));
        }
        consume_controller_operation_trust_in_tx(
            &mut transaction,
            &assignment,
            TaskBoardRemoteOperationKind::FetchArtifact,
            &request.request_sha256,
        )
        .await?;
        let stored = if let Some(existing) = existing {
            existing
        } else {
            insert_artifact_in_tx(&mut transaction, &input).await?;
            load_artifact_in_tx(
                &mut transaction,
                &request.binding.assignment_id,
                request.binding.fencing_epoch,
                &request.relative_path,
            )
            .await?
            .ok_or_else(|| db_error("persisted remote artifact disappeared"))?
        };
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit remote artifact response: {error}")))?;
        Ok(stored)
    }
}

fn validate_response_input(
    request: &RemoteArtifactFetchRequest,
    principal: &str,
    stored_at: &str,
) -> Result<(), CliError> {
    request
        .validate()
        .map_err(|error| db_error(format!("validate remote artifact response: {error}")))?;
    nonblank(principal, "remote artifact response principal")?;
    canonical_time(stored_at, "remote artifact response time")?;
    Ok(())
}
