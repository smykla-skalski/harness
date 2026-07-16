use super::*;

use crate::daemon::transport::remote_systemd_start_permit::{
    runtime_start_permit_is_live, runtime_start_permit_path,
};

impl ScriptedSystemd<'_> {
    pub(in super::super) fn starts(&self) -> u32 {
        self.state.borrow().starts
    }

    pub(in super::super) fn enabled(&self) -> bool {
        self.state.borrow().service.enabled
    }

    pub(in super::super) fn recovery_timer_enabled(&self) -> bool {
        self.state.borrow().service.recovery_timer_enabled
    }

    pub(in super::super) fn armed_before_disable(&self) -> bool {
        self.state.borrow().evidence.armed_before_disable
    }

    pub(in super::super) fn set_panic_on_daemon_enable(&self, enabled: bool) {
        self.state.borrow_mut().panics.panic_on_daemon_enable = enabled;
    }

    pub(in super::super) fn set_panic_on_candidate_health(&self, enabled: bool) {
        self.state.borrow_mut().panics.panic_on_candidate_health = enabled;
    }

    pub(in super::super) fn set_panic_on_stop(&self, enabled: bool) {
        self.state.borrow_mut().late_panics.panic_on_stop = enabled;
    }

    pub(in super::super) fn set_panic_on_old_start(&self, enabled: bool) {
        self.state.borrow_mut().panics.panic_on_old_start = enabled;
    }

    pub(in super::super) fn set_panic_on_spawn_observation(&self, enabled: bool) {
        self.state
            .borrow_mut()
            .late_panics
            .panic_on_spawn_observation = enabled;
    }

    pub(in super::super) fn set_panic_after_permit_reload_before_start(&self, enabled: bool) {
        self.state
            .borrow_mut()
            .late_panics
            .panic_after_permit_reload_before_start = enabled;
    }

    pub(in super::super) fn set_block_permit_creation_after_candidate_reload(&self, enabled: bool) {
        self.state
            .borrow_mut()
            .permit_behavior
            .block_permit_creation_after_candidate_reload = enabled;
    }

    pub(in super::super) fn set_fail_old_health(&self, enabled: bool) {
        self.state.borrow_mut().daemon_failures.fail_old_health = enabled;
    }

    pub(in super::super) fn set_fail_daemon_disable(&self, enabled: bool) {
        self.state.borrow_mut().daemon_failures.fail_daemon_disable = enabled;
    }

    pub(in super::super) fn set_fail_stop_after_inactive(&self, enabled: bool) {
        self.state
            .borrow_mut()
            .daemon_failures
            .fail_stop_after_inactive = enabled;
    }

    pub(in super::super) fn fail_next_daemon_reload(&self) {
        self.state.borrow_mut().daemon_reload_failures = 1;
    }

    pub(in super::super) fn set_fail_timer_enable(&self, enabled: bool) {
        self.state.borrow_mut().timer_failures.enable = enabled;
    }

    pub(in super::super) fn set_fail_timer_disable(&self, enabled: bool) {
        self.state.borrow_mut().timer_failures.disable = enabled;
    }

    pub(in super::super) fn set_fail_reload_after_start(&self, enabled: bool) {
        self.state
            .borrow_mut()
            .reload_failures
            .fail_reload_after_start = enabled;
    }

    pub(in super::super) fn set_fail_final_release_reload(&self, enabled: bool) {
        self.state
            .borrow_mut()
            .reload_failures
            .fail_final_release_reload = enabled;
    }

    pub(in super::super) fn fail_reloads_after_candidate_spawn(&self) {
        self.state.borrow_mut().persistent_reload_failure = Some(PersistentReloadFailure::new(
            PersistentReloadFailureTrigger::CandidateSpawn,
        ));
    }

    pub(in super::super) fn fail_reloads_after_final_inhibitor_release(&self) {
        self.state.borrow_mut().persistent_reload_failure = Some(PersistentReloadFailure::new(
            PersistentReloadFailureTrigger::FinalInhibitorRelease,
        ));
    }

    pub(in super::super) fn clear_persistent_reload_failure(&self) {
        self.state.borrow_mut().persistent_reload_failure = None;
    }

    pub(in super::super) fn set_inventory_conflict_from_pass(&self, pass: u32) {
        self.state.borrow_mut().inventory_conflict_from_pass = Some(pass);
    }

    pub(in super::super) fn set_attempt_external_start_on_inhibit(&self, enabled: bool) {
        self.state
            .borrow_mut()
            .permit_behavior
            .attempt_external_start_on_inhibit = enabled;
    }

    pub(in super::super) fn blocked_external_starts(&self) -> u32 {
        self.state.borrow().blocked_external_starts
    }

    pub(in super::super) fn set_drop_in_paths(&self, paths: &str) {
        self.state.borrow_mut().drop_in_paths = paths.to_string();
    }

    pub(in super::super) fn set_active(&self, active: bool) {
        self.state.borrow_mut().service.active = active;
        self.write_cgroup_populated(active);
    }

    pub(in super::super) fn active(&self) -> bool {
        self.state.borrow().service.active
    }

    pub(in super::super) fn inhibitor_installed(&self) -> bool {
        inhibitor_path(&self.fixture.unit)
            .expect("scripted inhibitor path")
            .is_file()
    }

    pub(in super::super) fn runtime_permit_installed(&self) -> bool {
        self.runtime_permit_path().is_file()
    }

    pub(in super::super) fn runtime_permit_live(&self) -> bool {
        self.runtime_permit_installed()
            && runtime_start_permit_is_live(&self.fixture.unit)
                .expect("inspect scripted runtime permit")
    }

    pub(in super::super) fn runtime_permit_path_exists(&self) -> bool {
        fs::symlink_metadata(self.runtime_permit_path()).is_ok()
    }

    pub(super) fn install_runtime_permit_blocker(&self) {
        let path = self.runtime_permit_path();
        let parent = path.parent().expect("scripted runtime permit parent");
        fs::create_dir_all(parent).expect("create scripted runtime permit directories");
        fs::set_permissions(
            parent.parent().expect("scripted runtime control root"),
            Permissions::from_mode(0o755),
        )
        .expect("set scripted runtime control root permissions");
        fs::set_permissions(parent, Permissions::from_mode(0o755))
            .expect("set scripted runtime permit directory permissions");
        fs::create_dir(&path).expect("create unrelated runtime permit blocker");
    }

    fn runtime_permit_path(&self) -> PathBuf {
        runtime_start_permit_path(&self.fixture.unit).expect("scripted runtime permit path")
    }

    pub(super) fn effective_drop_in_paths(&self, state: &ScriptedSystemdState) -> String {
        let runtime_permit = self
            .runtime_permit_installed()
            .then(|| self.runtime_permit_path());
        let persistent_inhibitor = self
            .inhibitor_installed()
            .then(|| inhibitor_path(&self.fixture.unit).expect("scripted inhibitor path"));
        let effective = runtime_permit.or(persistent_inhibitor);
        match (state.drop_in_paths.is_empty(), effective) {
            (true, None) => String::new(),
            (false, None) => state.drop_in_paths.clone(),
            (true, Some(path)) => path.display().to_string(),
            (false, Some(path)) => format!("{} {}", state.drop_in_paths, path.display()),
        }
    }
}
