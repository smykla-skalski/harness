use super::client::{
    RemoteExecutionHttpClient, RemoteExecutionHttpClientConfig, RemoteExecutionHttpError,
};
use super::controller::{
    RemoteExecutionControllerClient, RemoteExecutionControllerError, binding_error,
};
use super::controller_clock::ControllerClock;
#[cfg(test)]
use super::wire::{RemoteHeartbeatRequest, RemoteHeartbeatResponse};
use super::wire_conversion::domain_host_advertisement;
use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteHostSelection, TaskBoardRemoteHostTrustFence,
    TaskBoardRemoteOperationTrustFence,
};

impl RemoteExecutionControllerClient {
    pub(crate) fn connect(
        trust: &TaskBoardRemoteHostTrustFence,
    ) -> Result<Self, RemoteExecutionControllerError> {
        let config = client_config(&trust.config)?;
        Ok(Self {
            host_id: trust.config.host_id.clone(),
            client: RemoteExecutionHttpClient::new(config)?,
            clock: ControllerClock::System,
            retained_trust: Some(trust.clone()),
        })
    }

    #[cfg(test)]
    pub(super) fn new_for_tests(host_id: &str, client: RemoteExecutionHttpClient) -> Self {
        Self {
            host_id: host_id.to_string(),
            client,
            clock: ControllerClock::System,
            retained_trust: None,
        }
    }

    #[cfg(test)]
    pub(super) fn new_for_tests_with_times(
        host_id: &str,
        client: RemoteExecutionHttpClient,
        times: impl IntoIterator<Item = String>,
    ) -> Self {
        Self {
            host_id: host_id.to_string(),
            client,
            clock: ControllerClock::queued(times),
            retained_trust: None,
        }
    }

    #[cfg(test)]
    pub(super) fn new_for_tests_with_retained_trust(
        host_id: &str,
        client: RemoteExecutionHttpClient,
        trust: TaskBoardRemoteHostTrustFence,
    ) -> Self {
        Self {
            host_id: host_id.to_string(),
            client,
            clock: ControllerClock::System,
            retained_trust: Some(trust),
        }
    }

    #[cfg(test)]
    pub(super) fn new_for_tests_with_retained_trust_and_times(
        host_id: &str,
        client: RemoteExecutionHttpClient,
        trust: TaskBoardRemoteHostTrustFence,
        times: impl IntoIterator<Item = String>,
    ) -> Self {
        Self {
            host_id: host_id.to_string(),
            client,
            clock: ControllerClock::queued(times),
            retained_trust: Some(trust),
        }
    }

    pub(crate) async fn refresh_observation(
        &self,
        db: &AsyncDaemonDb,
    ) -> Result<TaskBoardRemoteHostSelection, RemoteExecutionControllerError> {
        let expected = db.task_board_remote_host_trust_fence(&self.host_id).await?;
        self.require_client_trust(&expected, true)?;
        let advertisement = domain_host_advertisement(self.client.advertise().await?)
            .map_err(RemoteExecutionHttpError::from)?;
        let received_at = self.clock.now();
        if advertisement.host_id != self.host_id {
            return Err(binding_error("remote advertisement identity mismatched").into());
        }
        db.record_task_board_execution_host_observation_fenced(
            &advertisement,
            &received_at,
            &expected,
        )
        .await
        .map_err(Into::into)
    }

    #[cfg(test)]
    pub(crate) async fn heartbeat(
        &self,
        db: &AsyncDaemonDb,
        request: &RemoteHeartbeatRequest,
    ) -> Result<RemoteHeartbeatResponse, RemoteExecutionControllerError> {
        // Disabling a host clears its observation, so the operation fence would otherwise
        // reject with "no observed instance"; check the enabled state first for a clear reason.
        let host = db.task_board_remote_host_trust_fence(&self.host_id).await?;
        if !host.config.enabled {
            return Err(binding_error("remote execution host is disabled").into());
        }
        let trust = self.current_operation_trust(db).await?;
        if request.host_id != self.host_id
            || request.host_instance_id != trust.observed_host_instance_id
        {
            return Err(binding_error("remote heartbeat identity mismatched").into());
        }
        self.client.heartbeat(request).await.map_err(Into::into)
    }

    pub(super) async fn current_operation_trust(
        &self,
        db: &AsyncDaemonDb,
    ) -> Result<TaskBoardRemoteOperationTrustFence, RemoteExecutionControllerError> {
        self.current_operation_trust_with_enabled(db, true).await
    }

    pub(super) async fn current_source_recovery_trust(
        &self,
        db: &AsyncDaemonDb,
    ) -> Result<TaskBoardRemoteOperationTrustFence, RemoteExecutionControllerError> {
        self.current_operation_trust_with_enabled(db, false).await
    }

    pub(super) async fn current_operation_trust_for(
        &self,
        db: &AsyncDaemonDb,
        kind: crate::daemon::db::TaskBoardRemoteOperationKind,
        assignment_id: &str,
    ) -> Result<TaskBoardRemoteOperationTrustFence, RemoteExecutionControllerError> {
        if kind.requires_enabled_host() {
            return self.current_operation_trust_with_enabled(db, true).await;
        }
        let current = db
            .task_board_remote_lifecycle_operation_trust_fence(assignment_id, kind)
            .await?;
        self.require_client_trust(&current.host, false)?;
        Ok(current)
    }

    pub(super) async fn current_configured_host_trust_for_lifecycle(
        &self,
        db: &AsyncDaemonDb,
    ) -> Result<TaskBoardRemoteHostTrustFence, RemoteExecutionControllerError> {
        let current = db.task_board_remote_host_trust_fence(&self.host_id).await?;
        self.require_client_trust(&current, false)?;
        Ok(current)
    }

    pub(super) async fn current_stable_host_trust_for_replay(
        &self,
        db: &AsyncDaemonDb,
    ) -> Result<TaskBoardRemoteHostTrustFence, RemoteExecutionControllerError> {
        let current = db.task_board_remote_host_trust_fence(&self.host_id).await?;
        if let Some(retained) = self.retained_trust.as_ref() {
            let stable = retained.config.host_id == current.config.host_id
                && retained.config.endpoint == current.config.endpoint
                && retained.config.certificate_fingerprint
                    == current.config.certificate_fingerprint
                && retained.config.credential_reference == current.config.credential_reference
                && current.configuration_revision >= retained.configuration_revision;
            if !stable || !self.client.has_config(&client_config(&current.config)?) {
                return Err(binding_error(
                    "remote replay client transport trust configuration is stale",
                )
                .into());
            }
        }
        Ok(current)
    }

    async fn current_operation_trust_with_enabled(
        &self,
        db: &AsyncDaemonDb,
        require_enabled: bool,
    ) -> Result<TaskBoardRemoteOperationTrustFence, RemoteExecutionControllerError> {
        let current = db
            .task_board_remote_operation_trust_fence(&self.host_id)
            .await?;
        self.require_client_trust(&current.host, require_enabled)?;
        Ok(current)
    }

    fn require_client_trust(
        &self,
        current: &TaskBoardRemoteHostTrustFence,
        require_enabled: bool,
    ) -> Result<(), RemoteExecutionControllerError> {
        if require_enabled && !current.config.enabled {
            return Err(binding_error("remote execution host is disabled").into());
        }
        if self
            .retained_trust
            .as_ref()
            .is_some_and(|retained| retained != current)
        {
            return Err(
                binding_error("remote execution client trust configuration is stale").into(),
            );
        }
        if self.retained_trust.is_some()
            && !self.client.has_config(&client_config(&current.config)?)
        {
            return Err(
                binding_error("remote execution client trust configuration is stale").into(),
            );
        }
        Ok(())
    }
}

fn client_config(
    host: &crate::task_board::TaskBoardExecutionHostConfig,
) -> Result<RemoteExecutionHttpClientConfig, super::client::RemoteExecutionHttpError> {
    RemoteExecutionHttpClientConfig::new(
        &host.endpoint,
        &host.certificate_fingerprint,
        &host.credential_reference,
        &host.host_id,
    )
}
