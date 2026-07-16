use std::cell::RefCell;
use std::fs::{self, Permissions};
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, config::DbConfig};
use tempfile::tempdir_in;

use crate::daemon::transport::remote_systemd_inhibitor::inhibitor_path;
use crate::daemon::transport::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use crate::daemon::transport::remote_systemd_upgrade_lifecycle::{
    RemoteSystemdOperationPlan, RemoteSystemdUpgradePlan,
};
use crate::errors::{CliError, CliErrorKind};

#[path = "support/health.rs"]
mod health;
#[path = "support/inventory.rs"]
mod inventory;
#[path = "support/recovery_output.rs"]
mod recovery_output;
#[path = "support/systemd_commands.rs"]
mod systemd_commands;
#[path = "support/systemd_state.rs"]
mod systemd_state;

pub(super) const OLD_BINARY: &str = "#!/bin/sh\necho 'harness 46.0.2'\n";
const CANDIDATE_BINARY: &str = "#!/bin/sh\necho 'harness 47.0.1'\n";

pub(super) struct UpgradeFixture {
    _temp: tempfile::TempDir,
    _private_temp: tempfile::TempDir,
    pub(super) binary: PathBuf,
    pub(super) unit: PathBuf,
    pub(super) state: PathBuf,
    cgroup_events: PathBuf,
    pub(super) operation: RemoteSystemdOperationPlan,
    pub(super) upgrade_plan: RemoteSystemdUpgradePlan,
}

impl UpgradeFixture {
    pub(super) fn new() -> Self {
        let temp = tempdir_in(env!("CARGO_MANIFEST_DIR")).expect("trusted tempdir");
        let private_temp = tempdir_in(std::env::temp_dir()).expect("private tempdir");
        let binary = temp.path().join("installed-harness");
        let candidate = temp.path().join("candidate-harness");
        let unit = temp.path().join("harness-remote.service");
        let environment = temp.path().join("harness-remote.env");
        let state = temp.path().join("state").join("harness");
        let store = private_temp
            .path()
            .join("transactions")
            .join("harness-remote");
        let cgroup_events = temp.path().join("cgroup.events");
        write_executable(&binary, OLD_BINARY);
        write_executable(&candidate, CANDIDATE_BINARY);
        fs::write(
            &unit,
            format!(
                "[Service]\nType=simple\nEnvironmentFile={}\nEnvironment=HARNESS_DAEMON_DATA_HOME=%S/harness-remote\nEnvironment=XDG_DATA_HOME=%S/harness-remote\nEnvironment=HARNESS_DAEMON_OWNERSHIP=external\nExecStart={} remote serve\nDynamicUser=yes\nStateDirectory=harness-remote\nStateDirectoryMode=0700\n",
                environment.display(),
                binary.display(),
            ),
        )
        .expect("write unit");
        fs::write(&environment, "RUST_LOG=harness=info\n").expect("write environment");
        fs::create_dir_all(state.join("daemon").join("external")).expect("state dirs");
        fs::write(state.join("config.json"), "before\n").expect("write config");
        fs::write(&cgroup_events, "populated 1\nfrozen 0\n").expect("write cgroup events");
        let database = state.join("daemon").join("external").join("harness.db");
        seed_database(&database);
        let operation = RemoteSystemdOperationPlan {
            unit: "harness-remote".to_string(),
            binary_path: binary.clone(),
            unit_path: unit.clone(),
            environment_path: environment,
            state_path: state.clone(),
            store_path: store,
            controller_path: binary.clone(),
            readiness_timeout: Duration::from_secs(1),
            stabilization_window: Duration::ZERO,
        };
        let upgrade_plan = RemoteSystemdUpgradePlan {
            operation: operation.clone(),
            candidate_path: candidate,
        };
        Self {
            _temp: temp,
            _private_temp: private_temp,
            binary,
            unit,
            state,
            cgroup_events,
            operation,
            upgrade_plan,
        }
    }

    pub(super) fn database(&self) -> PathBuf {
        self.state
            .join("daemon")
            .join("external")
            .join("harness.db")
    }
}

pub(super) struct ScriptedSystemd<'a> {
    fixture: &'a UpgradeFixture,
    fail_candidate_health: bool,
    state: RefCell<ScriptedSystemdState>,
}

struct ScriptedSystemdState {
    active: bool,
    enabled: bool,
    recovery_timer_enabled: bool,
    armed_before_disable: bool,
    daemon_enable_restores: u32,
    daemon_reload_failures: u8,
    fail_old_health: bool,
    fail_daemon_disable: bool,
    fail_stop_after_inactive: bool,
    fail_timer_disable: bool,
    fail_timer_enable: bool,
    fail_reload_after_start: bool,
    fail_final_release_reload: bool,
    persistent_reload_failure: Option<PersistentReloadFailure>,
    block_permit_creation_after_candidate_reload: bool,
    inventory_conflict_from_pass: Option<u32>,
    inventory_passes: u32,
    attempt_external_start_on_inhibit: bool,
    blocked_external_starts: u32,
    drop_in_paths: String,
    panic_on_candidate_health: bool,
    panic_on_daemon_enable: bool,
    panic_on_old_start: bool,
    panic_after_permit_reload_before_start: bool,
    panic_on_spawn_observation: bool,
    panic_on_stop: bool,
    starts: u32,
}

struct PersistentReloadFailure {
    trigger: PersistentReloadFailureTrigger,
    latched: bool,
}

#[derive(Clone, Copy)]
enum PersistentReloadFailureTrigger {
    CandidateSpawn,
    FinalInhibitorRelease,
}

impl PersistentReloadFailure {
    const fn new(trigger: PersistentReloadFailureTrigger) -> Self {
        Self {
            trigger,
            latched: false,
        }
    }

    fn message_if_triggered(
        &mut self,
        candidate_spawned: bool,
        final_inhibitor_released: bool,
    ) -> Option<&'static str> {
        if !self.latched
            && !self
                .trigger
                .reached(candidate_spawned, final_inhibitor_released)
        {
            return None;
        }
        self.latched = true;
        Some(self.trigger.message())
    }
}

impl PersistentReloadFailureTrigger {
    const fn reached(self, candidate_spawned: bool, final_inhibitor_released: bool) -> bool {
        match self {
            Self::CandidateSpawn => candidate_spawned,
            Self::FinalInhibitorRelease => final_inhibitor_released,
        }
    }

    const fn message(self) -> &'static str {
        match self {
            Self::CandidateSpawn => "forced persistent post-spawn daemon-reload failure",
            Self::FinalInhibitorRelease => {
                "forced persistent final inhibitor release reload failure"
            }
        }
    }
}

impl<'a> ScriptedSystemd<'a> {
    pub(super) fn new(fixture: &'a UpgradeFixture, fail_candidate_health: bool) -> Self {
        Self {
            fixture,
            fail_candidate_health,
            state: RefCell::new(ScriptedSystemdState {
                active: true,
                enabled: true,
                recovery_timer_enabled: false,
                armed_before_disable: false,
                daemon_enable_restores: 0,
                daemon_reload_failures: 0,
                fail_old_health: false,
                fail_daemon_disable: false,
                fail_stop_after_inactive: false,
                fail_timer_disable: false,
                fail_timer_enable: false,
                fail_reload_after_start: false,
                fail_final_release_reload: false,
                persistent_reload_failure: None,
                block_permit_creation_after_candidate_reload: false,
                inventory_conflict_from_pass: None,
                inventory_passes: 0,
                attempt_external_start_on_inhibit: false,
                blocked_external_starts: 0,
                drop_in_paths: String::new(),
                panic_on_candidate_health: false,
                panic_on_daemon_enable: false,
                panic_on_old_start: false,
                panic_after_permit_reload_before_start: false,
                panic_on_spawn_observation: false,
                panic_on_stop: false,
                starts: 0,
            }),
        }
    }

    pub(super) fn run(&self, args: &[String]) -> Result<RemoteSystemdCommandOutput, CliError> {
        let mut state = self.state.borrow_mut();
        if let Some(output) = inventory::run(args, self.fixture, &mut state) {
            return output;
        }
        match args.first().map(String::as_str) {
            Some("is-enabled") => return Ok(self.is_enabled_output(args, &state)),
            Some("enable") => {
                if recovery_output::is_timer_command(args) && state.fail_timer_enable {
                    return Err(CliErrorKind::workflow_io(
                        "forced recovery timer enable failure".to_string(),
                    )
                    .into());
                }
                Self::enable(args, &mut state);
            }
            Some("disable") => {
                if recovery_output::is_timer_command(args) && state.fail_timer_disable {
                    return Err(CliErrorKind::workflow_io(
                        "forced recovery timer disable failure".to_string(),
                    )
                    .into());
                }
                if !recovery_output::is_timer_command(args) && state.fail_daemon_disable {
                    return Err(CliErrorKind::workflow_io(
                        "forced daemon disable failure".to_string(),
                    )
                    .into());
                }
                self.disable(args, &mut state);
            }
            Some("show") => return Ok(self.show_output(args, &mut state)),
            Some("stop") => {
                state.active = false;
                self.write_cgroup_populated(false);
                if state.fail_stop_after_inactive {
                    state.fail_stop_after_inactive = false;
                    return Err(CliErrorKind::workflow_io(
                        "forced stop failure after service became inactive".to_string(),
                    )
                    .into());
                }
                assert!(!state.panic_on_stop, "simulated crash after service stop");
            }
            Some("start") => self.start(&mut state)?,
            Some("daemon-reload") => return self.daemon_reload(&mut state),
            Some("reset-failed") => {}
            other => {
                return Err(CliErrorKind::workflow_io(format!(
                    "unexpected scripted systemctl command: {other:?} ({args:?})"
                ))
                .into());
            }
        }
        Ok(success_output(String::new()))
    }
}

fn seed_database(path: &Path) {
    let connection = Connection::open(path).expect("open seed database");
    connection
        .execute_batch(
            "PRAGMA journal_mode=WAL;
             CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO schema_meta (key, value) VALUES ('version', '31');
             CREATE TABLE payload (value TEXT NOT NULL);
             INSERT INTO payload (value) VALUES ('before');",
        )
        .expect("seed database");
}

fn mutate_candidate_state(database: &Path, state: &Path) -> Result<(), CliError> {
    let connection = Connection::open(database).map_err(test_db_error)?;
    connection
        .set_db_config(DbConfig::SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, true)
        .map_err(test_db_error)?;
    connection
        .execute_batch(
            "PRAGMA wal_autocheckpoint=0;
             UPDATE schema_meta SET value = '35' WHERE key = 'version';
             CREATE TABLE IF NOT EXISTS candidate_startup (run INTEGER NOT NULL);
             INSERT INTO candidate_startup (run) VALUES (1);
             INSERT INTO payload (value)
             SELECT 'candidate'
             WHERE NOT EXISTS (SELECT 1 FROM payload WHERE value = 'candidate');",
        )
        .map_err(test_db_error)?;
    drop(connection);
    let wal = sidecar(database, "-wal");
    let wal_length = fs::metadata(&wal)
        .map_err(|error| CliErrorKind::workflow_io(format!("inspect candidate WAL: {error}")))?
        .len();
    if wal_length == 0 {
        return Err(CliErrorKind::workflow_io(
            "candidate migration did not leave an uncheckpointed WAL".to_string(),
        )
        .into());
    }
    fs::write(state.join("config.json"), "candidate\n")
        .map_err(|error| CliErrorKind::workflow_io(format!("mutate config: {error}")))?;
    fs::write(sidecar(database, "-shm"), [])
        .map_err(|error| CliErrorKind::workflow_io(format!("mutate shm: {error}")))?;
    Ok(())
}

fn test_db_error(error: rusqlite::Error) -> CliError {
    CliErrorKind::workflow_io(format!("mutate candidate database: {error}")).into()
}

pub(super) fn database_schema(path: &Path) -> i64 {
    Connection::open(path)
        .expect("open database")
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM schema_meta WHERE key = 'version'",
            [],
            |row| row.get(0),
        )
        .expect("schema version")
}

pub(super) fn database_values(path: &Path) -> Vec<String> {
    let connection = Connection::open(path).expect("open database");
    let mut statement = connection
        .prepare("SELECT value FROM payload ORDER BY rowid")
        .expect("prepare payload query");
    statement
        .query_map([], |row| row.get(0))
        .expect("query payload")
        .collect::<Result<Vec<_>, _>>()
        .expect("payload rows")
}

pub(super) fn installed_is_candidate(path: &Path) -> bool {
    fs::read_to_string(path)
        .expect("read installed binary")
        .contains("47.0.1")
}

pub(super) fn write_executable(path: &Path, contents: &str) {
    fs::write(path, contents).expect("write executable");
    fs::set_permissions(path, Permissions::from_mode(0o755)).expect("chmod executable");
}

pub(super) fn sidecar(database: &Path, suffix: &str) -> PathBuf {
    let mut value = database.as_os_str().to_os_string();
    value.push(suffix);
    PathBuf::from(value)
}

pub(super) fn success_output(stdout: String) -> RemoteSystemdCommandOutput {
    command_output(0, stdout)
}

fn command_output(exit_code: i32, stdout: impl Into<String>) -> RemoteSystemdCommandOutput {
    RemoteSystemdCommandOutput {
        exit_code,
        stdout: stdout.into(),
        stderr: String::new(),
    }
}
