use std::path::Path;

use super::remote_assignment_model::TaskBoardRemoteMutationOutcome;
use super::remote_assignment_result_adoption::TaskBoardRemoteResultAdoptionOutcome;
use super::remote_assignment_start_authority::{
    TaskBoardRemoteExecutorIdentity, TaskBoardRemoteExecutorStartAuthority,
    TaskBoardRemoteExecutorStartIoPermit, failed_at_claimed, lifecycle, settings_fence,
};
use super::remote_executor_run::{TaskBoardRemoteExecutorRun, TaskBoardRemoteRuntimeProvenance};
use super::remote_offer_receipts::TaskBoardRemoteOfferReceipt;
use super::remote_operation_trust::TaskBoardRemoteOperationTrustFence;
use super::remote_settlement_receipts::TaskBoardRemoteSettlementReceipt;
use super::{remote_assignment_result_adoption, remote_executor_run, remote_offer_receipts};
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::TaskBoardWorkflowExecutionCas;
use crate::task_board::remote_wire::wire::{
    RemoteOfferRequest, RemoteSettledRequest, RemoteSettledResponse, RemoteStatusResponse,
};

pub(crate) trait RemoteAssignmentStartSettlementQueries: Send + Sync {
    async fn adopt_task_board_remote_executor_start(
        &self,
        permit: &TaskBoardRemoteExecutorStartIoPermit,
        project_dir: &Path,
        started_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn adopt_task_board_remote_executor_start_owned(
        &self,
        permit: &TaskBoardRemoteExecutorStartIoPermit,
        project_dir: &Path,
        started_at: &str,
        owner_instance_id: &str,
        owner_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn expire_task_board_remote_executor_start_without_run(
        &self,
        authority: &TaskBoardRemoteExecutorStartAuthority,
        reason: &str,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn fail_task_board_remote_executor_start_without_run(
        &self,
        permit: &TaskBoardRemoteExecutorStartIoPermit,
        response: &RemoteStatusResponse,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn authorize_task_board_remote_executor_provisioning(
        &self,
        authority: &TaskBoardRemoteExecutorStartAuthority,
        authorized_at: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorStartAuthority>, CliError>;

    async fn revoke_task_board_remote_executor_start_after_cleanup(
        &self,
        authority: &TaskBoardRemoteExecutorStartAuthority,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn abandon_task_board_remote_executor_start_after_restart(
        &self,
        authority: &TaskBoardRemoteExecutorStartAuthority,
        successor_instance_id: &str,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    async fn abandon_task_board_remote_executor_claim_after_restart(
        &self,
        assignment_id: &str,
        identity: &TaskBoardRemoteExecutorIdentity,
        successor_instance_id: &str,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError>;

    #[cfg(test)]
    async fn claim_task_board_remote_settlement_io_authority(
        &self,
        request: &RemoteSettledRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<RemoteSettledResponse>, CliError>;

    async fn claim_task_board_remote_settlement_io_authority_fenced(
        &self,
        request: &RemoteSettledRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<RemoteSettledResponse>, CliError>;

    async fn record_task_board_remote_settlement_response(
        &self,
        request: &RemoteSettledRequest,
        response: &RemoteSettledResponse,
        authenticated_principal: &str,
    ) -> Result<TaskBoardRemoteSettlementReceipt, CliError>;

    async fn task_board_remote_executor_run(
        &self,
        offer: &RemoteOfferRequest,
        run_id: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorRun>, CliError>;

    async fn task_board_remote_runtime_provenance(
        &self,
        execution_id: &str,
        run_id: &str,
    ) -> Result<Option<TaskBoardRemoteRuntimeProvenance>, CliError>;

    async fn exact_task_board_remote_offer_receipt(
        &self,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
    ) -> Result<Option<TaskBoardRemoteOfferReceipt>, CliError>;

    async fn adopt_task_board_remote_terminal_result(
        &self,
        expected: &TaskBoardWorkflowExecutionCas,
        assignment_id: &str,
        fencing_epoch: u64,
    ) -> Result<TaskBoardRemoteResultAdoptionOutcome, CliError>;
}

impl RemoteAssignmentStartSettlementQueries for AsyncDaemonDb {
    async fn adopt_task_board_remote_executor_start(
        &self,
        permit: &TaskBoardRemoteExecutorStartIoPermit,
        project_dir: &Path,
        started_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        lifecycle::adopt_task_board_remote_executor_start(self, permit, project_dir, started_at)
            .await
    }

    async fn adopt_task_board_remote_executor_start_owned(
        &self,
        permit: &TaskBoardRemoteExecutorStartIoPermit,
        project_dir: &Path,
        started_at: &str,
        owner_instance_id: &str,
        owner_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        lifecycle::adopt_task_board_remote_executor_start_owned(
            self,
            permit,
            project_dir,
            started_at,
            owner_instance_id,
            owner_at,
        )
        .await
    }

    async fn expire_task_board_remote_executor_start_without_run(
        &self,
        authority: &TaskBoardRemoteExecutorStartAuthority,
        reason: &str,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        lifecycle::expire_task_board_remote_executor_start_without_run(
            self,
            authority,
            reason,
            observed_at,
        )
        .await
    }

    async fn fail_task_board_remote_executor_start_without_run(
        &self,
        permit: &TaskBoardRemoteExecutorStartIoPermit,
        response: &RemoteStatusResponse,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        failed_at_claimed::fail_task_board_remote_executor_start_without_run(self, permit, response)
            .await
    }

    async fn authorize_task_board_remote_executor_provisioning(
        &self,
        authority: &TaskBoardRemoteExecutorStartAuthority,
        authorized_at: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorStartAuthority>, CliError> {
        settings_fence::authorize_task_board_remote_executor_provisioning(
            self,
            authority,
            authorized_at,
        )
        .await
    }

    async fn revoke_task_board_remote_executor_start_after_cleanup(
        &self,
        authority: &TaskBoardRemoteExecutorStartAuthority,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        settings_fence::revoke_task_board_remote_executor_start_after_cleanup(
            self,
            authority,
            observed_at,
        )
        .await
    }

    async fn abandon_task_board_remote_executor_start_after_restart(
        &self,
        authority: &TaskBoardRemoteExecutorStartAuthority,
        successor_instance_id: &str,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        settings_fence::abandon_task_board_remote_executor_start_after_restart(
            self,
            authority,
            successor_instance_id,
            observed_at,
        )
        .await
    }

    async fn abandon_task_board_remote_executor_claim_after_restart(
        &self,
        assignment_id: &str,
        identity: &TaskBoardRemoteExecutorIdentity,
        successor_instance_id: &str,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        settings_fence::abandon_task_board_remote_executor_claim_after_restart(
            self,
            assignment_id,
            identity,
            successor_instance_id,
            observed_at,
        )
        .await
    }

    #[cfg(test)]
    async fn claim_task_board_remote_settlement_io_authority(
        &self,
        request: &RemoteSettledRequest,
        authenticated_principal: &str,
        authority_at: &str,
    ) -> Result<Option<RemoteSettledResponse>, CliError> {
        super::remote_settlement_controller::claim_task_board_remote_settlement_io_authority(
            self,
            request,
            authenticated_principal,
            authority_at,
        )
        .await
    }

    async fn claim_task_board_remote_settlement_io_authority_fenced(
        &self,
        request: &RemoteSettledRequest,
        authenticated_principal: &str,
        authority_at: &str,
        trust: &TaskBoardRemoteOperationTrustFence,
    ) -> Result<Option<RemoteSettledResponse>, CliError> {
        super::remote_settlement_controller::claim_task_board_remote_settlement_io_authority_fenced(
            self,
            request,
            authenticated_principal,
            authority_at,
            trust,
        )
        .await
    }

    async fn record_task_board_remote_settlement_response(
        &self,
        request: &RemoteSettledRequest,
        response: &RemoteSettledResponse,
        authenticated_principal: &str,
    ) -> Result<TaskBoardRemoteSettlementReceipt, CliError> {
        super::remote_settlement_controller::record_task_board_remote_settlement_response(
            self,
            request,
            response,
            authenticated_principal,
        )
        .await
    }

    async fn task_board_remote_executor_run(
        &self,
        offer: &RemoteOfferRequest,
        run_id: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorRun>, CliError> {
        remote_executor_run::task_board_remote_executor_run(self, offer, run_id).await
    }

    async fn task_board_remote_runtime_provenance(
        &self,
        execution_id: &str,
        run_id: &str,
    ) -> Result<Option<TaskBoardRemoteRuntimeProvenance>, CliError> {
        remote_executor_run::task_board_remote_runtime_provenance(self, execution_id, run_id).await
    }

    async fn exact_task_board_remote_offer_receipt(
        &self,
        request: &RemoteOfferRequest,
        authenticated_principal: &str,
    ) -> Result<Option<TaskBoardRemoteOfferReceipt>, CliError> {
        remote_offer_receipts::exact_task_board_remote_offer_receipt(
            self,
            request,
            authenticated_principal,
        )
        .await
    }

    async fn adopt_task_board_remote_terminal_result(
        &self,
        expected: &TaskBoardWorkflowExecutionCas,
        assignment_id: &str,
        fencing_epoch: u64,
    ) -> Result<TaskBoardRemoteResultAdoptionOutcome, CliError> {
        remote_assignment_result_adoption::adopt_task_board_remote_terminal_result(
            self,
            expected,
            assignment_id,
            fencing_epoch,
        )
        .await
    }
}
