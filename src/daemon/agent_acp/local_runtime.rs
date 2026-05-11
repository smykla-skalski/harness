use std::path::{Path, PathBuf};
use std::process::Child;
use std::sync::Arc;

use serde::Serialize;
use tokio::sync::broadcast;
use tokio::sync::mpsc;
use uuid::Uuid;

use self::rollback::rollback_registration_best_effort;
use self::snapshots::{
    StartedSnapshotInput, preferred_project_dir, started_snapshot, stream_event,
};
use crate::agents::acp::catalog::AcpAgentDescriptor;
use crate::agents::acp::connection::SpawnConfig;
use crate::agents::acp::permission::{PermissionMode, recording_log_path_for_session};
use crate::agents::acp::supervision::{AcpSessionSupervisor, SupervisionConfig};
use crate::agents::kind::DisconnectReason;
use crate::agents::runtime::{AgentRuntime, runtime_for_name};
use crate::daemon::index;
use crate::daemon::protocol::StreamEvent;
use crate::errors::{CliError, CliErrorKind};

use super::active::{
    ActiveAcpProcess, ActiveAcpSession, ActiveAcpTasks, LiveEventPersistence, SharedStderrTail,
    spawn_event_forwarder, spawn_protocol_disconnect_forwarder, spawn_watchdog_forwarder,
};
use super::manager::{
    AcpAgentManagerHandle, AcpAgentSnapshot, AcpAgentStartRequest, AcpOrchestrationRegistration,
    PERMISSION_RESPONSE_DEADLINE, process_fault_policy_enabled, process_pooling_disabled,
};
use super::permission_bridge::PermissionBridgeHandle;
use super::pool_key::AcpProcessPoolKey;
use super::prompt_gate::{PromptGate, PromptOwner, prompt_text};
use super::protocol::{
    AcpSessionRequestConfig, SpawnProtocolInput, SpawnedAcpProtocol, spawn_protocol_task,
};

mod reused_session;
mod rollback;
mod sandbox_state;
mod snapshots;

impl AcpAgentManagerHandle {
    #[cfg(test)]
    pub(super) fn start_descriptor(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
        descriptor: &AcpAgentDescriptor,
    ) -> Result<AcpAgentSnapshot, CliError> {
        self.start_descriptor_with_pooling_disabled(session_id, request, descriptor, false)
    }

    pub(in crate::daemon::agent_acp) fn start_descriptor_with_pooling_disabled(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
        descriptor: &AcpAgentDescriptor,
        disable_pooling: bool,
    ) -> Result<AcpAgentSnapshot, CliError> {
        let project_dir = self.resolve_project_dir(session_id, request.project_dir.as_deref())?;
        let acp_id = format!("agent-acp-{}", Uuid::new_v4());
        let session_config = AcpSessionRequestConfig::from_request(request, descriptor);
        let spawn = build_spawn_config(descriptor, &session_config, &project_dir)?;
        let process_key = AcpProcessPoolKey::from_spawn_inputs(
            descriptor,
            request,
            session_id,
            &spawn,
            &project_dir,
        );
        if process_fault_policy_enabled() {
            self.ensure_process_key_start_allowed(process_key.as_str())?;
        }
        let process_key = if disable_pooling || process_pooling_disabled() {
            format!("{}:isolated:{acp_id}", process_key.as_str())
        } else {
            process_key.as_str().to_string()
        };
        let input = DescriptorStartInput {
            acp_id: &acp_id,
            session_id,
            request,
            descriptor,
            project_dir: &project_dir,
            process_key: &process_key,
        };
        let _lifecycle = self.process_lifecycle_guard()?;
        if self.start_requested_after_shutdown() {
            return Err(CliErrorKind::workflow_io(
                "ACP manager is shutting down; new ACP agents are blocked".to_string(),
            )
            .into());
        }
        if let Some(snapshot) = self.try_start_reused_session(input)? {
            return Ok(snapshot);
        }
        self.start_new_process_session(input, &spawn)
    }

    fn start_new_process_session(
        &self,
        input: DescriptorStartInput<'_>,
        spawn: &SpawnConfig,
    ) -> Result<AcpAgentSnapshot, CliError> {
        let mut child = spawn.spawn().map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "spawn ACP agent '{}': {error}",
                input.descriptor.id
            ))
        })?;
        let context = self.build_started_process_context(input, &mut child);
        let protocol = self.attach_protocol_for_started_process(input, &context, &mut child)?;
        let registration = self.register_started_orchestration_agent(
            input,
            input.descriptor.id.as_str(),
            &context.display_name,
            &mut child,
            &protocol,
        )?;
        let event_task = spawn_event_forwarder(
            self.sender(),
            protocol.events,
            self.live_event_persistence(
                input.session_id,
                &registration.agent_id,
                &input.descriptor.id,
            ),
        );
        if protocol.start.send(()).is_err() {
            protocol.protocol.abort();
            protocol.batcher.abort();
            event_task.abort();
            let _ = child.kill();
            rollback_registration_best_effort(
                self,
                input.session_id,
                input.acp_id,
                &registration.agent_id,
                "startup_failed",
            );
            return Err(CliErrorKind::workflow_io(format!(
                "ACP protocol task exited before startup for '{}'",
                input.descriptor.id
            ))
            .into());
        }
        let snapshot = started_snapshot(StartedSnapshotInput {
            acp_id: input.acp_id,
            session_id: input.session_id,
            request: input.request,
            agent_id: &registration.agent_id,
            display_name: &registration.display_name,
            supervisor: &context.supervisor,
            project_dir: input.project_dir,
            process_key: input.process_key,
            permission_log_path: context.permission_log_path,
        });
        let process = Arc::new(ActiveAcpProcess::new(
            child,
            Arc::clone(&context.supervisor),
            protocol.handle,
            context.prompt_gate,
            context.stderr_tail,
            ActiveAcpTasks {
                protocol: protocol.protocol,
                batcher: protocol.batcher,
                event: event_task,
            },
        ));
        if let Err(error) = self.activate_started_session(
            input,
            snapshot.clone(),
            context.permissions,
            process,
            protocol.disconnects,
            context.supervisor,
        ) {
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
        Ok(snapshot)
    }

    fn build_started_process_context(
        &self,
        input: DescriptorStartInput<'_>,
        child: &mut Child,
    ) -> StartedProcessContext {
        let stderr_tail = SharedStderrTail::spawn(child.stderr.take());
        let supervisor = Arc::new(AcpSessionSupervisor::new(
            child,
            SupervisionConfig::default()
                .with_prompt_timeout(input.descriptor.prompt_timeout_seconds),
        ));
        let prompt_gate = PromptGate::default();
        let permissions = PermissionBridgeHandle::spawn(
            input.acp_id.to_string(),
            input.session_id.to_string(),
            self.sender(),
        );
        let permission_log_path = input
            .request
            .record_permissions
            .then(|| recording_log_path_for_session(input.session_id));
        let display_name = input
            .request
            .name
            .clone()
            .unwrap_or_else(|| input.descriptor.display_name.clone());
        StartedProcessContext {
            permission_log_path,
            display_name,
            prompt_gate,
            supervisor,
            permissions,
            stderr_tail,
        }
    }

    fn attach_protocol_for_started_process(
        &self,
        input: DescriptorStartInput<'_>,
        context: &StartedProcessContext,
        child: &mut Child,
    ) -> Result<SpawnedAcpProtocol, CliError> {
        let initial_prompt_lease = prompt_text(input.request.prompt.as_deref())
            .map(|_| {
                context
                    .prompt_gate
                    .acquire(PromptOwner::new(input.acp_id, input.session_id))
                    .map_err(|error| CliErrorKind::workflow_io(error.message()))
            })
            .transpose()?;
        let permission_mode = context.permission_log_path.clone().map_or_else(
            || context.permissions.mode(PERMISSION_RESPONSE_DEADLINE),
            |log_path| PermissionMode::Recording { log_path },
        );
        spawn_protocol_task(
            child,
            SpawnProtocolInput {
                request: input.request,
                session_config: AcpSessionRequestConfig::from_request(
                    input.request,
                    input.descriptor,
                ),
                acp_id: input.acp_id,
                session_id: input.session_id,
                agent_name: context.display_name.clone(),
                runtime_name: input.descriptor.id.clone(),
                project_dir: input.project_dir.to_path_buf(),
                supervisor: &context.supervisor,
                permission_mode,
                initial_prompt_lease,
                manager: self.clone(),
            },
        )
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "attach ACP protocol for '{}': {error}",
                input.descriptor.id
            ))
            .into()
        })
    }

    fn register_started_orchestration_agent(
        &self,
        input: DescriptorStartInput<'_>,
        descriptor_id: &str,
        display_name: &str,
        child: &mut Child,
        protocol: &SpawnedAcpProtocol,
    ) -> Result<AcpOrchestrationRegistration, CliError> {
        self.register_orchestration_agent(
            input.session_id,
            input.acp_id,
            input.request,
            input.descriptor,
            display_name,
            None,
        )
        .inspect_err(|_| {
            protocol.protocol.abort();
            protocol.batcher.abort();
            let _ = child.kill();
        })
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "register ACP orchestration for '{descriptor_id}': {error}"
            ))
            .into()
        })
    }

    fn activate_started_session(
        &self,
        input: DescriptorStartInput<'_>,
        snapshot: AcpAgentSnapshot,
        permissions: PermissionBridgeHandle,
        process: Arc<ActiveAcpProcess>,
        disconnects: mpsc::Receiver<DisconnectReason>,
        supervisor: Arc<AcpSessionSupervisor>,
    ) -> Result<(), CliError> {
        let active = self.build_started_session(
            snapshot,
            permissions,
            Arc::clone(&process),
            AcpSessionRequestConfig::from_request(input.request, input.descriptor),
            disconnects,
            supervisor,
        );
        self.sessions_guard()?
            .insert(input.acp_id.to_string(), Arc::clone(&active));
        if let Err(error) = self.insert_process(input.process_key.to_string(), process) {
            self.rollback_started_session_after_process_insert_error(input);
            drop(active);
            return Err(error);
        }
        Ok(())
    }

    fn build_started_session(
        &self,
        snapshot: AcpAgentSnapshot,
        permissions: PermissionBridgeHandle,
        process: Arc<ActiveAcpProcess>,
        session_config: AcpSessionRequestConfig,
        disconnects: mpsc::Receiver<DisconnectReason>,
        supervisor: Arc<AcpSessionSupervisor>,
    ) -> Arc<ActiveAcpSession> {
        let active = Arc::new(ActiveAcpSession::new(
            snapshot,
            permissions,
            process,
            session_config,
        ));
        active.set_protocol_disconnect_task(spawn_protocol_disconnect_forwarder(
            self.clone(),
            Arc::downgrade(&active),
            disconnects,
        ));
        active.set_watchdog_task(spawn_watchdog_forwarder(
            self.clone(),
            Arc::downgrade(&active),
            supervisor,
        ));
        active
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn rollback_started_session_after_process_insert_error(&self, input: DescriptorStartInput<'_>) {
        if let Err(remove_error) = self
            .sessions_guard()
            .map(|mut sessions| sessions.remove(input.acp_id))
        {
            tracing::warn!(
                acp_id = input.acp_id,
                session_id = input.session_id,
                %remove_error,
                "failed to remove ACP session registration after process insert error"
            );
        }
    }

    pub(super) fn sender(&self) -> broadcast::Sender<StreamEvent> {
        self.state.sender.clone()
    }

    fn live_event_persistence(
        &self,
        session_id: &str,
        agent_id: &str,
        runtime: &str,
    ) -> Option<LiveEventPersistence> {
        self.state
            .db
            .get()
            .cloned()
            .map(|db| LiveEventPersistence::new(db, session_id, agent_id, runtime))
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn broadcast_event(
        stream_event: Option<StreamEvent>,
        event: &str,
        sender: &broadcast::Sender<StreamEvent>,
    ) {
        stream_event.map_or_else(
            || tracing::warn!(event, "failed to serialize ACP manager event"),
            |stream_event| {
                let _ = sender.send(stream_event);
            },
        );
    }

    pub(super) fn broadcast(&self, event: &str, payload: &impl Serialize) {
        Self::broadcast_event(stream_event(event, payload), event, &self.state.sender);
    }

    pub(super) fn resolve_project_dir(
        &self,
        session_id: &str,
        requested: Option<&str>,
    ) -> Result<PathBuf, CliError> {
        if let Some(path) = requested.filter(|value| !value.trim().is_empty()) {
            return Ok(PathBuf::from(path));
        }
        if let Some(path) = self.project_dir_from_db(session_id)? {
            return Ok(PathBuf::from(path));
        }
        let resolved = index::resolve_session(session_id)?;
        Ok(preferred_project_dir(
            &resolved.state.worktree_path,
            resolved.project.project_dir.as_deref(),
            resolved.project.repository_root.as_deref(),
            &resolved.project.context_root,
        ))
    }

    pub(super) fn project_dir_from_db(&self, session_id: &str) -> Result<Option<String>, CliError> {
        let Some(db) = self.state.db.get() else {
            return Ok(None);
        };
        let db = Self::daemon_db_guard(db)?;
        db.project_dir_for_session(session_id)
    }
}

fn build_spawn_config(
    descriptor: &AcpAgentDescriptor,
    session_config: &AcpSessionRequestConfig,
    project_dir: &Path,
) -> Result<SpawnConfig, CliError> {
    let runtime = resolve_spawn_runtime(descriptor)?;
    let model = session_config.requested_model();
    let effort = session_config.requested_effort();
    ensure_delivery_path(
        descriptor,
        runtime,
        model,
        session_config.model_via_session(),
        "model",
    )?;
    ensure_delivery_path(
        descriptor,
        runtime,
        effort,
        session_config.effort_via_session(),
        "effort",
    )?;

    let mut args = descriptor.launch_args.clone();
    if !session_config.model_via_session() {
        if let (Some(runtime), Some(model)) = (runtime, model) {
            if let Some(flag) = runtime.model_flag() {
                args.push(flag.to_string());
                args.push(model.to_string());
            }
        }
    }
    if !session_config.effort_via_session() {
        if let (Some(runtime), Some(effort)) = (runtime, effort) {
            args.extend(runtime.effort_args(effort));
        }
    }
    let env_overrides = if session_config.effort_via_session() {
        Vec::new()
    } else if let (Some(runtime), Some(effort)) = (runtime, effort) {
        runtime.effort_env(effort)
    } else {
        Vec::new()
    };

    Ok(SpawnConfig {
        command: descriptor.launch_command.clone(),
        args,
        env_passthrough: descriptor.env_passthrough.clone(),
        env_overrides,
        working_dir: project_dir.to_path_buf(),
    })
}

fn resolve_spawn_runtime(
    descriptor: &AcpAgentDescriptor,
) -> Result<Option<&'static dyn AgentRuntime>, CliError> {
    match &descriptor.spawn_configuration {
        crate::agents::acp::catalog::AcpSpawnConfiguration::DescriptorRuntime => {
            Ok(runtime_for_name(descriptor.id.as_str()))
        }
        crate::agents::acp::catalog::AcpSpawnConfiguration::Runtime { name } => {
            runtime_for_name(name).map(Some).ok_or_else(|| {
                CliErrorKind::workflow_io(format!(
                    "ACP descriptor '{}' references unknown runtime '{}'",
                    descriptor.id, name
                ))
                .into()
            })
        }
        crate::agents::acp::catalog::AcpSpawnConfiguration::None => Ok(None),
    }
}

fn ensure_delivery_path(
    descriptor: &AcpAgentDescriptor,
    runtime: Option<&'static dyn AgentRuntime>,
    requested: Option<&str>,
    via_session: bool,
    field_name: &str,
) -> Result<(), CliError> {
    if requested.is_none() || via_session || runtime.is_some() {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!(
        "ACP descriptor '{}' has no {field_name} delivery path for the requested session configuration",
        descriptor.id
    ))
    .into())
}

#[derive(Clone, Copy)]
struct DescriptorStartInput<'a> {
    acp_id: &'a str,
    session_id: &'a str,
    request: &'a AcpAgentStartRequest,
    descriptor: &'a AcpAgentDescriptor,
    project_dir: &'a Path,
    process_key: &'a str,
}

struct StartedProcessContext {
    permission_log_path: Option<PathBuf>,
    display_name: String,
    prompt_gate: PromptGate,
    supervisor: Arc<AcpSessionSupervisor>,
    permissions: PermissionBridgeHandle,
    stderr_tail: SharedStderrTail,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::acp::catalog::{
        AcpSessionConfigOptionBinding, AcpSessionConfiguration, AcpSessionEffortTransport,
        AcpSessionModelTransport, AcpSpawnConfiguration, DoctorProbe,
    };

    fn descriptor(id: &str) -> AcpAgentDescriptor {
        AcpAgentDescriptor {
            id: id.to_string(),
            display_name: "Fake ACP".to_string(),
            capabilities: Vec::new(),
            launch_command: "fake-acp".to_string(),
            launch_args: vec!["--acp".to_string()],
            env_passthrough: Vec::new(),
            spawn_configuration: Default::default(),
            model_catalog: None,
            install_hint: None,
            session_configuration: Default::default(),
            doctor_probe: DoctorProbe {
                command: "fake-acp".to_string(),
                args: vec!["--version".to_string()],
            },
            prompt_timeout_seconds: None,
            excluded_from_initial_default: false,
        }
    }

    #[test]
    fn build_spawn_config_skips_native_model_and_effort_injection_when_session_config_is_enabled() {
        let descriptor = AcpAgentDescriptor {
            id: "claude".to_string(),
            session_configuration: AcpSessionConfiguration {
                model: AcpSessionModelTransport::ConfigOption {
                    selector: AcpSessionConfigOptionBinding::default(),
                },
                effort: AcpSessionEffortTransport::ConfigOption {
                    selector: AcpSessionConfigOptionBinding::default(),
                },
            },
            ..descriptor("claude")
        };
        let request = AcpAgentStartRequest {
            model: Some("claude-sonnet-4-6".to_string()),
            effort: Some("high".to_string()),
            ..AcpAgentStartRequest::default()
        };
        let session_config = AcpSessionRequestConfig::from_request(&request, &descriptor);
        let spawn = build_spawn_config(&descriptor, &session_config, Path::new("/tmp"))
            .expect("build spawn config");

        assert_eq!(spawn.args, vec!["--acp"]);
        assert!(spawn.env_overrides.is_empty());
    }

    #[test]
    fn build_spawn_config_uses_explicit_runtime_mapping_when_descriptor_id_differs() {
        let descriptor = AcpAgentDescriptor {
            spawn_configuration: AcpSpawnConfiguration::Runtime {
                name: "claude".to_string(),
            },
            ..descriptor("claude-acp")
        };
        let request = AcpAgentStartRequest {
            model: Some("claude-sonnet-4-6".to_string()),
            effort: Some("high".to_string()),
            ..AcpAgentStartRequest::default()
        };
        let session_config = AcpSessionRequestConfig::from_request(&request, &descriptor);
        let spawn = build_spawn_config(&descriptor, &session_config, Path::new("/tmp"))
            .expect("build spawn config");

        assert_eq!(
            spawn.args,
            vec![
                "--acp".to_string(),
                "--model".to_string(),
                "claude-sonnet-4-6".to_string()
            ]
        );
        assert!(
            spawn
                .env_overrides
                .iter()
                .any(|(key, value)| key == "HARNESS_CLAUDE_THINKING_LEVEL" && value == "high")
        );
    }

    #[test]
    fn build_spawn_config_rejects_requested_model_without_spawn_or_session_delivery_path() {
        let descriptor = AcpAgentDescriptor {
            spawn_configuration: AcpSpawnConfiguration::None,
            ..descriptor("claude")
        };
        let request = AcpAgentStartRequest {
            model: Some("claude-sonnet-4-6".to_string()),
            ..AcpAgentStartRequest::default()
        };
        let session_config = AcpSessionRequestConfig::from_request(&request, &descriptor);
        let error = build_spawn_config(&descriptor, &session_config, Path::new("/tmp"))
            .expect_err("missing model delivery path should fail");

        assert!(format!("{error}").contains("model delivery path"));
    }
}
