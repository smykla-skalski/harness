use crate::daemon::transport::remote_systemd_start_permit::runtime_start_permit_is_live;

use super::*;

impl ScriptedSystemd<'_> {
    pub(super) fn daemon_reload(
        &self,
        state: &mut ScriptedSystemdState,
    ) -> Result<RemoteSystemdCommandOutput, CliError> {
        if state.daemon_reload_failures > 0 {
            state.daemon_reload_failures -= 1;
            return Err(
                CliErrorKind::workflow_io("forced daemon-reload failure".to_string()).into(),
            );
        }
        if let Some(message) = self.persistent_reload_failure(state) {
            return Err(CliErrorKind::workflow_io(message.to_string()).into());
        }
        if state.fail_reload_after_start && state.starts > 0 {
            state.fail_reload_after_start = false;
            return Err(CliErrorKind::workflow_io(
                "forced post-spawn daemon-reload failure".to_string(),
            )
            .into());
        }
        if state.fail_final_release_reload
            && state.daemon_enable_restores > 0
            && !self.inhibitor_installed()
        {
            state.fail_final_release_reload = false;
            return Err(CliErrorKind::workflow_io(
                "forced final inhibitor release reload failure".to_string(),
            )
            .into());
        }
        let permit_live = self.runtime_permit_is_live()?;
        if state.panic_after_permit_reload_before_start && permit_live {
            state.panic_after_permit_reload_before_start = false;
            panic!("simulated coordinator crash after permit reload before start");
        }
        if state.attempt_external_start_on_inhibit && self.inhibitor_installed() && !permit_live {
            state.blocked_external_starts += 1;
        }
        Ok(success_output(String::new()))
    }

    fn persistent_reload_failure(&self, state: &mut ScriptedSystemdState) -> Option<&'static str> {
        let candidate_spawned = state.starts > 0;
        let final_inhibitor_released =
            state.daemon_enable_restores > 0 && !self.inhibitor_installed();
        state
            .persistent_reload_failure
            .as_mut()?
            .message_if_triggered(candidate_spawned, final_inhibitor_released)
    }

    pub(super) fn is_enabled_output(
        &self,
        args: &[String],
        state: &ScriptedSystemdState,
    ) -> RemoteSystemdCommandOutput {
        let enabled = if recovery_output::is_timer_command(args) {
            state.recovery_timer_enabled
        } else {
            state.enabled
        };
        command_output(
            i32::from(!enabled),
            if enabled { "enabled\n" } else { "disabled\n" },
        )
    }

    pub(super) fn enable(args: &[String], state: &mut ScriptedSystemdState) {
        if recovery_output::is_timer_command(args) {
            state.recovery_timer_enabled = true;
        } else {
            assert!(
                !state.panic_on_daemon_enable,
                "simulated coordinator crash after durable commit"
            );
            state.enabled = true;
            state.daemon_enable_restores = state.daemon_enable_restores.saturating_add(1);
        }
    }

    pub(super) fn disable(&self, args: &[String], state: &mut ScriptedSystemdState) {
        if recovery_output::is_timer_command(args) {
            state.recovery_timer_enabled = false;
            return;
        }
        state.armed_before_disable = self
            .fixture
            .operation
            .store_path
            .join("armed.json")
            .is_file()
            && self
                .fixture
                .operation
                .store_path
                .join("recovery-controller")
                .is_file()
            && state.recovery_timer_enabled;
        state.enabled = false;
    }

    pub(super) fn show_output(
        &self,
        args: &[String],
        state: &mut ScriptedSystemdState,
    ) -> RemoteSystemdCommandOutput {
        assert_eq!(
            args.iter()
                .filter(|argument| argument.as_str() == "show")
                .count(),
            1,
            "scripted systemctl requires exactly one leading show command"
        );
        assert_eq!(args.first().map(String::as_str), Some("show"));
        assert!(
            !state.panic_on_spawn_observation || state.starts == 0,
            "simulated coordinator crash before post-spawn inhibitor reload"
        );
        let name = args.last().map(String::as_str).unwrap_or_default();
        if let Some(output) =
            recovery_output::show(&self.fixture.operation, name, state.recovery_timer_enabled)
        {
            return success_output(output);
        }
        let (active_state, sub_state, pid) = if state.active {
            ("active", "running", 4242)
        } else {
            ("inactive", "dead", 0)
        };
        let service_type = self.service_type();
        let timeout_start = if service_type == "notify" {
            "20min"
        } else {
            "1min 30s"
        };
        let drop_in_paths = self.effective_drop_in_paths(state);
        let mut output = success_output(format!(
            "ActiveState={active_state}\nSubState={sub_state}\nMainPID={pid}\nNRestarts=0\nFragmentPath={}\nDropInPaths={}\nUser=\nGroup=\nDynamicUser=yes\nStateDirectory=harness-remote\nStateDirectoryMode=0700\nType={service_type}\nNotifyAccess=main\nTimeoutStartUSec={timeout_start}\nKillMode=control-group\nEnvironment=HARNESS_DAEMON_DATA_HOME=%S/harness-remote XDG_DATA_HOME=%S/harness-remote HARNESS_DAEMON_OWNERSHIP=external\nEnvironmentFiles={} (ignore_errors=no)\nExecStart={{ path={}; argv[]={} remote serve; ignore_errors=no; }}\nExecStartPre=\nExecStartPost=\nExecCondition=\nExecReload=\nExecStop=\nExecStopPost=\nUnsetEnvironment=\nControlGroup=/harness-tests/{}\nHarnessTestControlGroupEvents={}\n",
            self.fixture.unit.display(),
            drop_in_paths,
            self.fixture.operation.environment_path.display(),
            self.fixture.binary.display(),
            self.fixture.binary.display(),
            self.fixture.operation.unit,
            self.fixture.cgroup_events.display(),
        ));
        let identity = if state.active {
            "User=harness-remote\nGroup=harness-remote\nDynamicUser=yes\nUID=62786\nGID=62786\nNeedDaemonReload=no\n"
        } else {
            "User=harness-remote\nGroup=harness-remote\nDynamicUser=yes\nUID=[not set]\nGID=[not set]\nNeedDaemonReload=no\n"
        };
        output.stdout = output
            .stdout
            .replace("%S/harness-remote", "/var/lib/harness-remote")
            .replacen("User=\nGroup=\nDynamicUser=yes\n", identity, 1);
        if state.block_permit_creation_after_candidate_reload
            && state.starts == 0
            && installed_is_candidate(&self.fixture.binary)
            && self.inhibitor_installed()
        {
            state.block_permit_creation_after_candidate_reload = false;
            self.install_runtime_permit_blocker();
        }
        output
    }

    fn service_type(&self) -> &'static str {
        let contents = fs::read_to_string(&self.fixture.unit).expect("read managed systemd unit");
        let values = contents
            .lines()
            .filter_map(|line| line.trim().split_once('='))
            .filter_map(|(key, value)| (key == "Type").then_some(value.trim()))
            .collect::<Vec<_>>();
        match values.as_slice() {
            ["simple"] => "simple",
            ["notify"] => "notify",
            _ => panic!("test unit must contain exactly one supported Type: {values:?}"),
        }
    }

    pub(super) fn start(&self, state: &mut ScriptedSystemdState) -> Result<(), CliError> {
        if !self.inhibitor_installed() {
            return Err(CliErrorKind::workflow_io(
                "systemd start lost its persistent inhibitor guard".to_string(),
            )
            .into());
        }
        if !self.runtime_permit_is_live()? {
            return Err(CliErrorKind::workflow_io(
                "systemd refused start without a live runtime permit".to_string(),
            )
            .into());
        }
        state.active = true;
        self.write_cgroup_populated(true);
        state.starts += 1;
        assert!(
            !state.panic_on_old_start || installed_is_candidate(&self.fixture.binary),
            "simulated coordinator crash before restored service verification"
        );
        if installed_is_candidate(&self.fixture.binary) {
            mutate_candidate_state(&self.fixture.database(), &self.fixture.state)?;
        }
        Ok(())
    }

    pub(super) fn write_cgroup_populated(&self, populated: bool) {
        fs::write(
            &self.fixture.cgroup_events,
            format!("populated {}\nfrozen 0\n", u8::from(populated)),
        )
        .expect("update scripted cgroup events");
    }

    fn runtime_permit_is_live(&self) -> Result<bool, CliError> {
        runtime_start_permit_is_live(&self.fixture.unit)
    }
}
