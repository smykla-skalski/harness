use std::path::Path;

use super::super::crash_boundary::CrashBoundary;
use super::super::database::{
    CRASH_MUTATED, CRASH_ORIGINAL, DatabaseCanary, assert_evidence_database, assert_live_database,
    establish_live_canary, mutate_live_canary,
};
use super::super::evidence::{
    assert_target_database_seal_persisted, failed_current_path, recovery_arm_phase,
    recovery_transaction_id,
};
use super::super::systemd_assertions::{
    assert_cached_runtime_permit_is_dead, assert_lifecycle_guards_released,
    assert_live_runtime_permit, assert_private_root_directory, assert_transaction_guard_active,
    root_path_matches,
};
use super::crash_coordinator::CrashCoordinator;
use super::{
    CRASH_ARM_TIMEOUT, CRASH_RECOVERY_TIMEOUT, RemoteSystemdUpgrade, file_digest,
    recovery_service_name, recovery_timer_name, running_binary_digest, systemd_property,
    wait_for_state,
};

#[derive(Clone, Copy)]
struct CrashCase {
    boundary: CrashBoundary,
    occurrence: usize,
    migrate_before_pause: bool,
}

const CRASH_CASES: [CrashCase; 3] = [
    CrashCase {
        boundary: CrashBoundary::PermitReloaded,
        occurrence: 1,
        migrate_before_pause: false,
    },
    CrashCase {
        boundary: CrashBoundary::ServiceSpawned,
        occurrence: 1,
        migrate_before_pause: false,
    },
    CrashCase {
        boundary: CrashBoundary::PermitRemoved,
        occurrence: 2,
        migrate_before_pause: true,
    },
];

struct CrashContext<'a> {
    upgrade: &'a RemoteSystemdUpgrade,
    binary_path: &'a Path,
    unit: &'a str,
    env_path: &'a Path,
    state_path: &'a Path,
    prior_sha256: &'a str,
    target_sha256: String,
}

pub(super) fn prove_runtime_permit_crash_matrix(
    upgrade: &RemoteSystemdUpgrade,
    binary_path: &Path,
    unit: &str,
    env_path: &Path,
    state_path: &Path,
    prior_sha256: &str,
) -> Result<(), String> {
    let target_sha256 = file_digest(&upgrade.crash_candidate_path, "crash upgrade candidate")?;
    if target_sha256 == prior_sha256 {
        return Err("crash candidate did not differ from the installed generation".to_string());
    }
    let context = CrashContext {
        upgrade,
        binary_path,
        unit,
        env_path,
        state_path,
        prior_sha256,
        target_sha256,
    };
    for case in CRASH_CASES {
        context.run_case(case)?;
    }
    Ok(())
}

impl CrashContext<'_> {
    fn run_case(&self, case: CrashCase) -> Result<(), String> {
        establish_live_canary(self.state_path, CRASH_ORIGINAL)?;
        let mut coordinator = CrashCoordinator::start(
            &self.upgrade.crash_coordinator_path,
            self.binary_path,
            self.unit,
            self.env_path,
            &self.upgrade.crash_candidate_path,
            case.boundary,
            case.occurrence,
        )?;
        coordinator.assert_actual_root_upgrade_process()?;
        if case.migrate_before_pause {
            wait_for_state(
                "first candidate start before database migration",
                CRASH_ARM_TIMEOUT,
                || self.first_start_is_ready(&coordinator),
            )?;
            mutate_live_canary(self.state_path, CRASH_ORIGINAL, CRASH_MUTATED)?;
        }
        coordinator.wait_until_paused(CRASH_ARM_TIMEOUT)?;
        self.assert_paused_boundary(&coordinator, case)?;
        let transaction_id = recovery_transaction_id(self.upgrade.transaction_path())?;
        let evidence_path = failed_current_path(self.upgrade.transaction_path(), &transaction_id);
        coordinator.kill()?;
        let expected_evidence = if case.migrate_before_pause {
            CRASH_MUTATED
        } else {
            CRASH_ORIGINAL
        };
        wait_for_state(
            "automatic boundary-crash recovery to finish",
            CRASH_RECOVERY_TIMEOUT,
            || self.recovery_finished(&evidence_path, expected_evidence),
        )
    }

    fn first_start_is_ready(&self, coordinator: &CrashCoordinator) -> Result<bool, String> {
        let service = format!("{}.service", self.unit);
        let timer = recovery_timer_name(self.unit);
        let ready = systemd_property(&service, "ActiveState")? == "active"
            && systemd_property(&service, "SubState")? == "running"
            && systemd_property(&service, "UnitFileState")? == "disabled"
            && systemd_property(&timer, "ActiveState")? == "active"
            && systemd_property(&timer, "UnitFileState")? == "enabled"
            && systemd_property(coordinator.service(), "MainPID")? == coordinator.pid().to_string()
            && recovery_arm_phase(self.upgrade.transaction_path())?.as_deref()
                == Some("rollback_ready")
            && root_path_matches(
                "-f",
                &self
                    .upgrade
                    .transaction_path()
                    .join("pending/manifest.json"),
            )?
            && file_digest(self.binary_path, "installed crash candidate")? == self.target_sha256
            && running_binary_digest(&service)? == self.target_sha256;
        if !ready {
            return Ok(false);
        }
        assert_transaction_guard_active(self.unit, &systemd_property(&service, "DropInPaths")?)?;
        Ok(true)
    }

    fn assert_paused_boundary(
        &self,
        coordinator: &CrashCoordinator,
        case: CrashCase,
    ) -> Result<(), String> {
        self.assert_armed_transaction(coordinator)?;
        let service = format!("{}.service", self.unit);
        let drop_in_paths = systemd_property(&service, "DropInPaths")?;
        match case.boundary {
            CrashBoundary::PermitReloaded => {
                assert_service_not_spawned(&service)?;
                assert_live_runtime_permit(self.unit, coordinator.pid(), &drop_in_paths)?;
            }
            CrashBoundary::ServiceSpawned => {
                self.assert_target_service_spawned(&service)?;
                assert_live_runtime_permit(self.unit, coordinator.pid(), &drop_in_paths)?;
            }
            CrashBoundary::PermitRemoved => {
                self.assert_target_service_spawned(&service)?;
                assert_cached_runtime_permit_is_dead(self.unit, &drop_in_paths)?;
            }
        }
        if case.occurrence == 2 {
            assert_target_database_seal_persisted(self.upgrade.transaction_path())?;
            assert_live_database(
                self.state_path,
                CRASH_MUTATED,
                "sealed migrated database at second-start crash boundary",
            )?;
        }
        Ok(())
    }

    fn assert_armed_transaction(&self, coordinator: &CrashCoordinator) -> Result<(), String> {
        let timer = recovery_timer_name(self.unit);
        if systemd_property(coordinator.service(), "MainPID")? != coordinator.pid().to_string()
            || systemd_property(&timer, "ActiveState")? != "active"
            || systemd_property(&timer, "UnitFileState")? != "enabled"
            || recovery_arm_phase(self.upgrade.transaction_path())?.as_deref()
                != Some("rollback_ready")
            || !root_path_matches(
                "-f",
                &self
                    .upgrade
                    .transaction_path()
                    .join("pending/manifest.json"),
            )?
            || file_digest(self.binary_path, "installed crash candidate")? != self.target_sha256
        {
            return Err(format!(
                "systemd transaction was not safely armed at {}",
                self.unit
            ));
        }
        let service = format!("{}.service", self.unit);
        if systemd_property(&service, "UnitFileState")? == "disabled" {
            Ok(())
        } else {
            Err(format!(
                "systemd service was enabled at crash boundary: {service}"
            ))
        }
    }

    fn assert_target_service_spawned(&self, service: &str) -> Result<(), String> {
        let active = systemd_property(service, "ActiveState")?;
        let main_pid = systemd_property(service, "MainPID")?
            .parse::<u32>()
            .map_err(|error| format!("parse {service} MainPID: {error}"))?;
        if main_pid > 0
            && matches!(active.as_str(), "active" | "activating")
            && running_binary_digest(service)? == self.target_sha256
        {
            Ok(())
        } else {
            Err(format!(
                "target service was not spawned at crash boundary: ActiveState={active}, MainPID={main_pid}"
            ))
        }
    }

    fn recovery_finished(
        &self,
        evidence_path: &Path,
        expected_evidence: DatabaseCanary,
    ) -> Result<bool, String> {
        let service = format!("{}.service", self.unit);
        let timer = recovery_timer_name(self.unit);
        let recovery = recovery_service_name(self.unit);
        let recovered = systemd_property(&service, "ActiveState")? == "active"
            && systemd_property(&service, "SubState")? == "running"
            && systemd_property(&service, "UnitFileState")? == "enabled"
            && systemd_property(&timer, "ActiveState")? == "active"
            && systemd_property(&timer, "UnitFileState")? == "enabled"
            && systemd_property(&recovery, "ActiveState")? == "inactive"
            && systemd_property(&recovery, "Result")? == "success"
            && !root_path_matches("-e", &self.upgrade.transaction_path().join("armed.json"))?
            && !root_path_matches("-e", &self.upgrade.transaction_path().join("pending"))?
            && file_digest(self.binary_path, "recovered installed binary")? == self.prior_sha256
            && running_binary_digest(&service)? == self.prior_sha256;
        if !recovered {
            return Ok(false);
        }
        assert_lifecycle_guards_released(self.unit, &systemd_property(&service, "DropInPaths")?)?;
        assert_private_root_directory(
            self.upgrade.transaction_path(),
            "systemd transaction store",
        )?;
        assert_private_root_directory(evidence_path, "crash failed-current evidence")?;
        assert_live_database(
            self.state_path,
            CRASH_ORIGINAL,
            "timer-recovered live database",
        )?;
        assert_evidence_database(
            evidence_path,
            expected_evidence,
            "retained crash failed-current database",
        )?;
        Ok(true)
    }
}

fn assert_service_not_spawned(service: &str) -> Result<(), String> {
    let active = systemd_property(service, "ActiveState")?;
    let main_pid = systemd_property(service, "MainPID")?;
    if main_pid == "0" && !matches!(active.as_str(), "active" | "activating") {
        Ok(())
    } else {
        Err(format!(
            "service spawned before its selected boundary: ActiveState={active}, MainPID={main_pid}"
        ))
    }
}
