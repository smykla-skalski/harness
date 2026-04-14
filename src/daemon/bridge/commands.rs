use super::*;

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum BridgeCommand {
    /// Start the unified host bridge.
    Start(BridgeStartArgs),
    /// Stop the running host bridge, if any.
    Stop(BridgeStopArgs),
    /// Print the current bridge status.
    Status(BridgeStatusArgs),
    /// Reconfigure the running bridge without restarting it.
    Reconfigure(BridgeReconfigureArgs),
    /// Install a per-user `LaunchAgent` that starts the bridge at login.
    InstallLaunchAgent(BridgeInstallLaunchAgentArgs),
    /// Remove the bridge `LaunchAgent` and clean up persisted state.
    RemoveLaunchAgent(BridgeRemoveLaunchAgentArgs),
}

impl Execute for BridgeCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Start(args) => args.execute(context),
            Self::Stop(args) => args.execute(context),
            Self::Status(args) => args.execute(context),
            Self::Reconfigure(args) => args.execute(context),
            Self::InstallLaunchAgent(args) => args.execute(context),
            Self::RemoveLaunchAgent(args) => args.execute(context),
        }
    }
}

/// Adopt the running daemon's root for the duration of this bridge
/// subcommand so its state writes target whatever daemon is actually
/// running (sandboxed managed, `harness daemon dev`, or a plain
/// `daemon serve`), regardless of which env vars the calling terminal
/// had set. See [`crate::daemon::discovery`] for the scan algorithm.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn adopt_daemon_root_for_bridge_command(command: &'static str) {
    match discovery::adopt_running_daemon_root() {
        AdoptionOutcome::AlreadyCoherent { root } => {
            tracing::debug!(
                command,
                root = %root.display(),
                "bridge: daemon root already coherent"
            );
        }
        AdoptionOutcome::Adopted { from, to } => {
            tracing::info!(
                command,
                from = %from.display(),
                to = %to.display(),
                "bridge: adopted running daemon root"
            );
        }
        AdoptionOutcome::NoRunningDaemon { default_root } => {
            tracing::warn!(
                command,
                default_root = %default_root.display(),
                "bridge: no running daemon found; bridge state will land at the default root"
            );
        }
    }
}

impl Execute for BridgeStartArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        ensure_host_context("bridge-start")?;
        adopt_daemon_root_for_bridge_command("bridge-start");
        cleanup_legacy_bridge_artifacts();
        let config = self.config.resolve()?;
        if matches_running_config(&config)? {
            if self.daemon {
                let report = status_report()?;
                print_status_plain(&report);
                return Ok(0);
            }
            return Err(CliErrorKind::workflow_io(
                "bridge is already running with the requested configuration; use `harness bridge stop` before running it in the foreground",
            )
            .into());
        }
        let _ = stop_bridge();
        if self.daemon {
            return start_detached(&config);
        }
        run_bridge_server(&config)
    }
}

impl Execute for BridgeStopArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        adopt_daemon_root_for_bridge_command("bridge-stop");
        cleanup_legacy_bridge_artifacts();
        let report = stop_bridge()?;
        if self.json {
            print_json(&report)?;
        } else {
            print_status_plain(&report);
        }
        Ok(0)
    }
}

impl Execute for BridgeStatusArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        adopt_daemon_root_for_bridge_command("bridge-status");
        let report = status_report()?;
        if self.plain {
            print_status_plain(&report);
        } else {
            print_json(&report)?;
        }
        Ok(0)
    }
}

impl Execute for BridgeInstallLaunchAgentArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        ensure_host_context("bridge-install-launch-agent")?;
        adopt_daemon_root_for_bridge_command("bridge-install-launch-agent");
        cleanup_legacy_bridge_artifacts();
        let config = self.config.resolve()?;
        write_bridge_config(&config.persisted)?;
        let harness_binary = current_exe().map_err(|error| {
            CliErrorKind::workflow_io(format!("resolve current harness binary: {error}"))
        })?;
        let plist = render_launch_agent_plist(&harness_binary);
        let plist_path = launch_agent_plist_path()?;
        if let Some(parent) = plist_path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                CliErrorKind::workflow_io(format!("create launch agent dir: {error}"))
            })?;
        }
        write_text(&plist_path, &plist)?;
        if cfg!(target_os = "macos") {
            best_effort_bootout(BRIDGE_LAUNCH_AGENT_LABEL);
            bootstrap_agent(&plist_path)?;
        }
        println!("installed {}", plist_path.display());
        Ok(0)
    }
}

impl Execute for BridgeReconfigureArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        ensure_host_context("bridge-reconfigure")?;
        adopt_daemon_root_for_bridge_command("bridge-reconfigure");
        cleanup_legacy_bridge_artifacts();
        let request = self.request()?;
        let report = BridgeClient::from_state_file()?.reconfigure(&request)?;
        if self.json {
            print_json(&report)?;
        } else {
            print_status_plain(&report);
        }
        Ok(0)
    }
}

impl Execute for BridgeRemoveLaunchAgentArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        ensure_host_context("bridge-remove-launch-agent")?;
        adopt_daemon_root_for_bridge_command("bridge-remove-launch-agent");
        cleanup_legacy_bridge_artifacts();
        let plist_path = launch_agent_plist_path()?;
        let existed = plist_path.is_file();
        if existed && cfg!(target_os = "macos") {
            best_effort_bootout(BRIDGE_LAUNCH_AGENT_LABEL);
        }
        if existed {
            fs::remove_file(&plist_path).map_err(|error| {
                CliErrorKind::workflow_io(format!("remove bridge plist: {error}"))
            })?;
        }
        clear_bridge_state()?;
        if self.json {
            let json = json!({
                "removed": existed,
                "path": plist_path.display().to_string(),
            });
            println!(
                "{}",
                serde_json::to_string_pretty(&json).unwrap_or_default()
            );
        } else if existed {
            println!("removed {}", plist_path.display());
        } else {
            println!("not installed");
        }
        Ok(0)
    }
}

impl BridgeReconfigureArgs {
    fn request(&self) -> Result<BridgeReconfigureSpec, CliError> {
        let request = BridgeReconfigureSpec {
            enable: self.enable.clone(),
            disable: self.disable.clone(),
            force: self.force,
        };
        request.validate()?;
        Ok(request)
    }
}
