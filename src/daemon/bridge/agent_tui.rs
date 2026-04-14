use super::{BridgeServer, AgentTuiStartSpec, AgentTuiSnapshot, CliError, BRIDGE_CAPABILITY_AGENT_TUI, CliErrorKind, BridgeCapability, spawn_agent_tui_process, Arc, BridgeSnapshotContext, snapshot_from_process, AgentTuiStatus, BridgeActiveTui, thread, deliver_deferred_prompts, Duration, BridgeAgentTuiMetadata, HostBridgeCapabilityManifest, stringify_metadata_map};

impl BridgeServer {
    pub(super) fn start_agent_tui(
        &self,
        spec: AgentTuiStartSpec,
    ) -> Result<AgentTuiSnapshot, CliError> {
        if !self
            .capabilities()?
            .contains_key(BRIDGE_CAPABILITY_AGENT_TUI)
        {
            return Err(CliErrorKind::sandbox_feature_disabled(
                BridgeCapability::AgentTui.sandbox_feature(),
            )
            .into());
        }
        if self.active_tuis()?.contains_key(&spec.tui_id) {
            return Err(CliErrorKind::workflow_io(format!(
                "agent TUI '{}' is already active in host bridge",
                spec.tui_id
            ))
            .into());
        }
        let process = spawn_agent_tui_process(
            &spec.session_id,
            &spec.tui_id,
            spec.profile.clone(),
            &spec.project_dir,
            spec.size,
            spec.prompt.clone(),
        )?;
        let deferred_prompt = spec.prompt.clone();
        let deferred_runtime = spec.profile.runtime.clone();
        let deferred_tui_id = spec.tui_id.clone();
        let process = Arc::new(process);
        let context = BridgeSnapshotContext {
            session_id: spec.session_id,
            agent_id: spec.agent_id,
            tui_id: spec.tui_id.clone(),
            profile: spec.profile,
            project_dir: spec.project_dir,
            transcript_path: spec.transcript_path,
        };
        let snapshot =
            snapshot_from_process(&context.borrowed(), &process, AgentTuiStatus::Running)?;
        self.active_tuis()?.insert(
            spec.tui_id,
            BridgeActiveTui {
                process,
                context,
                created_at: snapshot.created_at.clone(),
            },
        );
        self.update_agent_tui_metadata()?;

        // Send prompt in background so the bridge response returns immediately.
        {
            let process = Arc::clone(&self.active_tui(&deferred_tui_id)?.process);
            let prompt = deferred_prompt
                .as_deref()
                .filter(|p| !p.is_empty())
                .map(ToString::to_string);
            thread::spawn(move || {
                deliver_deferred_prompts(
                    &process,
                    &deferred_runtime,
                    &deferred_tui_id,
                    prompt.as_deref().unwrap_or(""),
                    None,
                );
            });
        }

        Ok(snapshot)
    }

    pub(super) fn get_agent_tui(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let active = self.active_tui(tui_id)?;
        let mut status = AgentTuiStatus::Running;
        let mut exit_code = None;
        let mut signal = None;
        if let Some(exit_status) = active.process.try_wait()? {
            status = AgentTuiStatus::Exited;
            exit_code = Some(exit_status.exit_code());
            signal = exit_status.signal().map(ToString::to_string);
            let _ = self.active_tuis()?.remove(tui_id);
            self.update_agent_tui_metadata()?;
        }
        let mut snapshot =
            snapshot_from_process(&active.context.borrowed(), &active.process, status)?;
        snapshot.created_at = active.created_at;
        snapshot.exit_code = exit_code;
        snapshot.signal = signal;
        Ok(snapshot)
    }

    pub(super) fn stop_agent_tui(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let active = self.active_tuis()?.remove(tui_id).ok_or_else(|| {
            CliErrorKind::session_not_active(format!(
                "agent TUI '{tui_id}' is not active in host bridge"
            ))
        })?;
        active.process.kill()?;
        let _ = active.process.wait_timeout(Duration::from_millis(500))?;
        let mut snapshot = snapshot_from_process(
            &active.context.borrowed(),
            &active.process,
            AgentTuiStatus::Stopped,
        )?;
        snapshot.created_at = active.created_at;
        self.update_agent_tui_metadata()?;
        Ok(snapshot)
    }

    pub(super) fn active_tui(&self, tui_id: &str) -> Result<BridgeActiveTui, CliError> {
        self.active_tuis()?.get(tui_id).cloned().ok_or_else(|| {
            CliErrorKind::session_not_active(format!(
                "agent TUI '{tui_id}' is not active in host bridge"
            ))
            .into()
        })
    }

    pub(super) fn update_agent_tui_metadata(&self) -> Result<(), CliError> {
        let active_sessions = self.active_tuis()?.len();
        let metadata = BridgeAgentTuiMetadata { active_sessions };
        let manifest = HostBridgeCapabilityManifest {
            enabled: true,
            healthy: true,
            transport: "unix".to_string(),
            endpoint: Some(self.socket_path.display().to_string()),
            metadata: stringify_metadata_map(&metadata),
        };
        self.capabilities()?
            .insert(BRIDGE_CAPABILITY_AGENT_TUI.to_string(), manifest);
        self.persist_state()
    }
}
