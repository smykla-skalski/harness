use super::{BridgeServer, BridgeCodexProcess, CliError, stringify_metadata_map, BRIDGE_CAPABILITY_CODEX, HostBridgeCapabilityManifest, state, Arc, BridgeCapability, ResolvedBridgeConfig, CliErrorKind, spawn_codex_process, spawn_codex_monitor, BRIDGE_CAPABILITY_AGENT_TUI, BTreeSet, launch_agent_plist_path, current_exe, write_text, render_launch_agent_plist, Ordering, MutexGuard, BTreeMap, BridgeActiveTui, PersistedBridgeConfig};

impl BridgeServer {
    #[expect(
        clippy::cognitive_complexity,
        reason = "state update plus tracing/event emission is intentionally linear"
    )]
    pub(super) fn set_codex_process(&self, process: BridgeCodexProcess) -> Result<(), CliError> {
        let endpoint = process.endpoint.clone();
        let port = process.metadata.port;
        let pid = process.child.id();
        let metadata = stringify_metadata_map(&process.metadata);
        self.capabilities()?.insert(
            BRIDGE_CAPABILITY_CODEX.to_string(),
            HostBridgeCapabilityManifest {
                enabled: true,
                healthy: true,
                transport: "websocket".to_string(),
                endpoint: Some(endpoint.clone()),
                metadata,
            },
        );
        *self.codex()? = Some(process);
        tracing::info!(%endpoint, port, pid, "codex host bridge capability enabled");
        state::append_event_best_effort(
            "info",
            &format!("codex host bridge ready on {endpoint} (pid {pid})"),
        );
        self.persist_state()
    }

    pub(super) fn mark_codex_unhealthy(&self, last_exit_status: &str) -> Result<(), CliError> {
        let mut capabilities = self.capabilities()?;
        let Some(codex) = capabilities.get_mut(BRIDGE_CAPABILITY_CODEX) else {
            return Ok(());
        };
        let endpoint = codex.endpoint.clone().unwrap_or_default();
        let port = codex
            .metadata
            .get("port")
            .and_then(|value| value.parse::<u16>().ok())
            .unwrap_or_default();
        codex.healthy = false;
        codex
            .metadata
            .insert("last_exit_status".to_string(), last_exit_status.to_string());
        drop(capabilities);
        tracing::warn!(
            %endpoint,
            port,
            exit_status = %last_exit_status,
            "codex host bridge capability became unhealthy"
        );
        state::append_event_best_effort(
            "warn",
            &format!("codex host bridge became unhealthy on {endpoint}: {last_exit_status}"),
        );
        self.persist_state()
    }

    pub(super) fn enable_capability(
        self: &Arc<Self>,
        capability: BridgeCapability,
        config: &ResolvedBridgeConfig,
    ) -> Result<(), CliError> {
        match capability {
            BridgeCapability::Codex => self.enable_codex(config),
            BridgeCapability::AgentTui => self.enable_agent_tui(),
        }
    }

    pub(super) fn enable_agent_tui(&self) -> Result<(), CliError> {
        self.update_agent_tui_metadata()
    }

    pub(super) fn enable_codex(
        self: &Arc<Self>,
        config: &ResolvedBridgeConfig,
    ) -> Result<(), CliError> {
        let binary = config.codex_binary.as_ref().ok_or_else(|| {
            CliErrorKind::workflow_io("codex capability requires a resolved codex binary")
        })?;
        let _ = self.clear_codex(false);
        let process = spawn_codex_process(binary, config.codex_port)?;
        self.set_codex_process(process)?;
        spawn_codex_monitor(Arc::clone(self));
        Ok(())
    }

    pub(super) fn pre_disable_check(
        &self,
        capability: BridgeCapability,
        force: bool,
    ) -> Result<(), CliError> {
        match capability {
            BridgeCapability::Codex => Ok(()),
            BridgeCapability::AgentTui => self.ensure_agent_tui_can_disable(force),
        }
    }

    pub(super) fn disable_capability(
        &self,
        capability: BridgeCapability,
        force: bool,
    ) -> Result<(), CliError> {
        match capability {
            BridgeCapability::Codex => self.disable_codex(),
            BridgeCapability::AgentTui => self.disable_agent_tui(force),
        }
    }

    pub(super) fn clear_codex(&self, persist_state: bool) -> Result<(), CliError> {
        if let Ok(mut codex) = self.codex.lock()
            && let Some(process) = codex.as_mut()
        {
            let _ = process.child.kill();
            let _ = process.child.wait();
            codex.take();
        }
        self.capabilities()?.remove(BRIDGE_CAPABILITY_CODEX);
        if persist_state {
            self.persist_state()?;
        }
        Ok(())
    }

    pub(super) fn disable_codex(&self) -> Result<(), CliError> {
        self.clear_codex(true)
    }

    pub(super) fn disable_agent_tui(&self, force: bool) -> Result<(), CliError> {
        self.ensure_agent_tui_can_disable(force)?;
        if force {
            let tui_ids: Vec<String> = self.active_tuis()?.keys().cloned().collect();
            for tui_id in tui_ids {
                let _ = self.stop_agent_tui(&tui_id)?;
            }
        }
        self.capabilities()?.remove(BRIDGE_CAPABILITY_AGENT_TUI);
        self.persist_state()
    }

    pub(super) fn ensure_agent_tui_can_disable(&self, force: bool) -> Result<(), CliError> {
        let active_sessions = self.active_tuis()?.len();
        if active_sessions > 0 && !force {
            return Err(CliErrorKind::session_agent_conflict(format!(
            "agent-tui capability has {active_sessions} active session(s); rerun with --force to stop them first"
        ))
        .into());
        }
        Ok(())
    }

    pub(super) fn should_enable_capability(
        &self,
        capability: BridgeCapability,
        current_enabled: &BTreeSet<BridgeCapability>,
    ) -> Result<bool, CliError> {
        if !current_enabled.contains(&capability) {
            return Ok(true);
        }
        match capability {
            BridgeCapability::Codex => self.codex_requires_restart(),
            BridgeCapability::AgentTui => Ok(false),
        }
    }

    pub(super) fn codex_requires_restart(&self) -> Result<bool, CliError> {
        if self
            .capabilities()?
            .get(BRIDGE_CAPABILITY_CODEX)
            .is_some_and(|manifest| !manifest.healthy)
        {
            return Ok(true);
        }
        let mut codex = self.codex()?;
        let Some(process) = codex.as_mut() else {
            return Ok(true);
        };
        Ok(process.child.try_wait()?.is_some())
    }

    pub(super) fn sync_launch_agent_if_installed() -> Result<(), CliError> {
        let plist_path = launch_agent_plist_path()?;
        if !plist_path.is_file() {
            return Ok(());
        }
        let harness_binary = current_exe().map_err(|error| {
            CliErrorKind::workflow_io(format!("resolve current harness binary: {error}"))
        })?;
        write_text(&plist_path, &render_launch_agent_plist(&harness_binary))
    }

    pub(super) fn shutdown_requested(&self) -> bool {
        self.shutdown.load(Ordering::SeqCst)
    }

    pub(super) fn cleanup(&self) {
        if let Ok(mut active) = self.active_tuis.lock() {
            for (_, entry) in active.iter() {
                let _ = entry.process.kill();
            }
            active.clear();
        }
        if let Ok(mut codex) = self.codex.lock()
            && let Some(process) = codex.as_mut()
        {
            let _ = process.child.kill();
            let _ = process.child.wait();
            codex.take();
        }
    }

    pub(super) fn capabilities(
        &self,
    ) -> Result<MutexGuard<'_, BTreeMap<String, HostBridgeCapabilityManifest>>, CliError> {
        self.capabilities.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("bridge capabilities lock poisoned: {error}")).into()
        })
    }

    pub(super) fn active_tuis(
        &self,
    ) -> Result<MutexGuard<'_, BTreeMap<String, BridgeActiveTui>>, CliError> {
        self.active_tuis.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("bridge active map poisoned: {error}")).into()
        })
    }

    pub(super) fn codex(&self) -> Result<MutexGuard<'_, Option<BridgeCodexProcess>>, CliError> {
        self.codex.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("bridge codex lock poisoned: {error}")).into()
        })
    }

    pub(super) fn desired_config(&self) -> Result<MutexGuard<'_, PersistedBridgeConfig>, CliError> {
        self.desired_config.lock().map_err(|error| {
            CliErrorKind::workflow_io(format!("bridge desired config lock poisoned: {error}"))
                .into()
        })
    }
}
