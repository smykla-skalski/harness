use std::sync::Arc;

use crate::agents::acp::permission::recording_log_path_for_session;
use crate::errors::{CliError, CliErrorKind};

use super::rollback::rollback_registration_best_effort;
use super::snapshots::{ReusedSnapshotInput, reused_snapshot};
use super::{
    AcpAgentManagerHandle, AcpAgentSnapshot, AcpOrchestrationRegistration, ActiveAcpSession,
    DescriptorStartInput, PermissionBridgeHandle, prompt_text,
};

impl AcpAgentManagerHandle {
    pub(super) fn try_start_reused_session(
        &self,
        input: DescriptorStartInput<'_>,
    ) -> Result<Option<AcpAgentSnapshot>, CliError> {
        let Some(existing) = self.reusable_session_for_process_key(input.process_key)? else {
            return Ok(None);
        };
        let runtime_session_id = Self::attach_reused_protocol_session(&existing, input)?;
        let display_name = input
            .request
            .name
            .clone()
            .unwrap_or_else(|| input.descriptor.display_name.clone());
        let registration = self.register_reused_orchestration_agent(
            &existing,
            &runtime_session_id,
            input,
            &display_name,
        )?;
        let snapshot = reused_snapshot(ReusedSnapshotInput {
            acp_id: input.acp_id,
            session_id: input.session_id,
            request: input.request,
            agent_id: &registration.agent_id,
            display_name: &registration.display_name,
            source: &existing.snapshot_with_live_counts(),
            project_dir: input.project_dir,
            permission_log_path: input
                .request
                .record_permissions
                .then(|| recording_log_path_for_session(input.session_id)),
        });
        let active = Arc::new(ActiveAcpSession::new(
            snapshot.clone(),
            PermissionBridgeHandle::spawn(
                input.acp_id.to_string(),
                input.session_id.to_string(),
                self.sender(),
            ),
            existing.process(),
        ));
        if let Err(error) = self
            .sessions_guard()
            .map(|mut sessions| sessions.insert(input.acp_id.to_string(), active))
        {
            Self::detach_reused_session_after_registration_failure(&existing, input);
            rollback_registration_best_effort(
                self,
                input.session_id,
                input.acp_id,
                &registration.agent_id,
                "startup_failed",
            );
            return Err(error);
        }
        self.broadcast("acp_agent_started", &snapshot);
        Ok(Some(snapshot))
    }

    fn attach_reused_protocol_session(
        existing: &Arc<ActiveAcpSession>,
        input: DescriptorStartInput<'_>,
    ) -> Result<String, CliError> {
        (if let Some(prompt) = prompt_text(input.request.prompt.as_deref()) {
            existing.prompt_protocol_session(
                input.acp_id,
                input.session_id,
                input.project_dir.to_path_buf(),
                prompt,
            )
        } else {
            existing.attach_protocol_session(
                input.acp_id,
                input.session_id,
                input.project_dir.to_path_buf(),
            )
        })
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "attach reused ACP session '{}': {error}",
                input.descriptor.id
            ))
            .into()
        })
    }

    fn register_reused_orchestration_agent(
        &self,
        existing: &Arc<ActiveAcpSession>,
        runtime_session_id: &str,
        input: DescriptorStartInput<'_>,
        display_name: &str,
    ) -> Result<AcpOrchestrationRegistration, CliError> {
        self.register_orchestration_agent(
            input.session_id,
            input.acp_id,
            input.request,
            input.descriptor,
            display_name,
            Some(runtime_session_id),
        )
        .inspect_err(|_| Self::detach_reused_session_after_registration_failure(existing, input))
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion in leaf logging helper"
    )]
    fn detach_reused_session_after_registration_failure(
        existing: &Arc<ActiveAcpSession>,
        input: DescriptorStartInput<'_>,
    ) {
        if let Err(detach_error) = existing.detach_protocol_session(input.acp_id, input.session_id)
        {
            tracing::warn!(
                acp_id = input.acp_id,
                session_id = input.session_id,
                %detach_error,
                "failed to detach reused ACP session after orchestration registration failure"
            );
        }
    }
}
