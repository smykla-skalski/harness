use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

use super::super::remote_systemd_lifecycle::{unit_service_name, validate_canonical_unit_name};
use super::files::{io_error, regular_file_metadata, validate_absolute_path};

#[path = "model/database_seal.rs"]
mod database_seal;
#[path = "model/path_validation.rs"]
mod path_validation;

pub(super) use database_seal::DatabaseSeal;
use path_validation::validate_non_overlapping_paths;

pub(super) const MANIFEST_VERSION: u32 = 3;
pub(super) const PENDING_DIRECTORY: &str = "pending";
pub(super) const PREVIOUS_DIRECTORY: &str = "previous";
pub(super) const PREVIOUS_OLD_DIRECTORY: &str = ".previous-old";
pub(super) const MANIFEST_FILE: &str = "manifest.json";
pub(super) const CANDIDATE_FILE: &str = "candidate";
pub(super) const BINARY_FILE: &str = "binary";
pub(super) const UNIT_FILE: &str = "unit.service";
pub(super) const ENVIRONMENT_FILE: &str = "environment";
pub(super) const STATE_DIRECTORY: &str = "state";
pub(super) const OPERATION_LOCK_FILE: &str = "operation.lock";
pub(super) const RECOVERY_ARM_FILE: &str = "armed.json";
pub(super) const RECOVERY_CONTROLLER_FILE: &str = "recovery-controller";
pub(super) const SYSTEMD_START_TIMEOUT: &str = "20min";
pub(super) const RECOVERY_ARM_VERSION: u32 = 2;

#[derive(Debug, Clone)]
pub(crate) struct RemoteSystemdOperationPlan {
    pub unit: String,
    pub binary_path: PathBuf,
    pub unit_path: PathBuf,
    pub environment_path: PathBuf,
    pub state_path: PathBuf,
    pub store_path: PathBuf,
    pub controller_path: PathBuf,
    pub readiness_timeout: Duration,
    pub stabilization_window: Duration,
}

impl RemoteSystemdOperationPlan {
    pub(crate) fn validate(&self) -> Result<(), CliError> {
        validate_canonical_unit_name(&self.unit)?;
        for (label, path) in [
            ("installed binary", &self.binary_path),
            ("systemd unit", &self.unit_path),
            ("systemd environment", &self.environment_path),
            ("systemd state", &self.state_path),
            ("systemd transaction store", &self.store_path),
            ("systemd recovery controller source", &self.controller_path),
        ] {
            validate_absolute_path(label, path)?;
        }
        validate_non_overlapping_paths(self)?;
        if self.readiness_timeout.is_zero() {
            return Err(CliErrorKind::workflow_parse(
                "systemd readiness timeout must be greater than zero".to_string(),
            )
            .into());
        }
        if self.stabilization_window > self.readiness_timeout {
            return Err(CliErrorKind::workflow_parse(
                "systemd stabilization window cannot exceed readiness timeout".to_string(),
            )
            .into());
        }
        Ok(())
    }

    pub(super) fn service(&self) -> String {
        unit_service_name(&self.unit)
    }

    pub(super) fn pending_path(&self) -> PathBuf {
        self.store_path.join(PENDING_DIRECTORY)
    }

    pub(super) fn transaction_root(&self) -> Result<&Path, CliError> {
        self.store_path
            .parent()
            .ok_or_else(|| io_error("systemd transaction store has no parent"))
    }

    pub(super) fn previous_path(&self) -> PathBuf {
        self.store_path.join(PREVIOUS_DIRECTORY)
    }

    pub(super) fn recovery_arm_path(&self) -> PathBuf {
        self.store_path.join(RECOVERY_ARM_FILE)
    }

    pub(super) fn recovery_controller_path(&self) -> PathBuf {
        self.store_path.join(RECOVERY_CONTROLLER_FILE)
    }

    pub(super) fn recovery_service_name(&self) -> String {
        format!("{}-harness-recovery.service", self.unit)
    }

    pub(super) fn recovery_timer_name(&self) -> String {
        format!("{}-harness-recovery.timer", self.unit)
    }

    pub(super) fn recovery_service_path(&self) -> PathBuf {
        self.unit_path.with_file_name(self.recovery_service_name())
    }

    pub(super) fn recovery_timer_path(&self) -> PathBuf {
        self.unit_path.with_file_name(self.recovery_timer_name())
    }

    pub(super) fn state_reserve_path(&self) -> PathBuf {
        self.store_path.join("state-restore-reserve")
    }

    pub(super) fn state_inode_reserve_path(&self) -> PathBuf {
        self.store_path.join("state-restore-inode-reserve")
    }

    pub(super) fn binary_reserve_path(&self) -> Result<PathBuf, CliError> {
        self.binary_path
            .parent()
            .map(|parent| parent.join(format!(".harness-{}-binary-reserve", self.unit)))
            .ok_or_else(|| io_error("installed binary path has no parent"))
    }

    pub(super) fn binary_inode_reserve_path(&self) -> Result<PathBuf, CliError> {
        self.binary_path
            .parent()
            .map(|parent| parent.join(format!(".harness-{}-binary-inode-reserve", self.unit)))
            .ok_or_else(|| io_error("installed binary path has no parent"))
    }

    pub(super) fn failed_current_state_path(&self, transaction_id: &str) -> PathBuf {
        self.store_path
            .join(format!("failed-current-{transaction_id}"))
    }
}

#[derive(Debug, Clone)]
pub(crate) struct RemoteSystemdUpgradePlan {
    pub operation: RemoteSystemdOperationPlan,
    pub candidate_path: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum RecoveryOperation {
    Upgrade,
    Rollback,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum RecoveryPhase {
    Armed,
    RollbackReady,
    Committing,
    RollbackFinalizing,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct RecoveryArm {
    pub(super) arm_version: u32,
    pub(super) transaction_id: String,
    pub(super) operation: RecoveryOperation,
    pub(super) phase: RecoveryPhase,
    pub(super) unit: String,
    pub(super) binary_path: PathBuf,
    pub(super) unit_path: PathBuf,
    pub(super) environment_path: PathBuf,
    pub(super) state_path: PathBuf,
    pub(super) store_path: PathBuf,
    pub(super) readiness_timeout_seconds: u64,
    pub(super) stabilization_window_seconds: u64,
    pub(super) original_enabled: bool,
    pub(super) before_sha256: String,
    pub(super) target_sha256: String,
    #[serde(default)]
    pub(super) target_database_seal: Option<DatabaseSeal>,
}

impl RecoveryArm {
    pub(super) fn validate(&self) -> Result<(), CliError> {
        if self.arm_version != RECOVERY_ARM_VERSION {
            return Err(io_error(format!(
                "unsupported systemd recovery arm version {}",
                self.arm_version
            )));
        }
        if let Some(seal) = self.target_database_seal {
            seal.validate()?;
        }
        if self.phase == RecoveryPhase::Committing && self.target_database_seal.is_none() {
            return Err(io_error(format!(
                "committing systemd transaction {} has no target database seal",
                self.transaction_id
            )));
        }
        Ok(())
    }

    pub(super) fn plan(&self) -> Result<RemoteSystemdOperationPlan, CliError> {
        self.validate()?;
        let plan = RemoteSystemdOperationPlan {
            unit: self.unit.clone(),
            binary_path: self.binary_path.clone(),
            unit_path: self.unit_path.clone(),
            environment_path: self.environment_path.clone(),
            state_path: self.state_path.clone(),
            store_path: self.store_path.clone(),
            controller_path: PathBuf::from("/proc/self/exe"),
            readiness_timeout: Duration::from_secs(self.readiness_timeout_seconds),
            stabilization_window: Duration::from_secs(self.stabilization_window_seconds),
        };
        plan.validate()?;
        if plan.recovery_arm_path() != self.store_path.join(RECOVERY_ARM_FILE) {
            return Err(io_error("systemd recovery arm store path mismatch"));
        }
        Ok(plan)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RemoteSystemdRecoveryOutcome {
    Deferred,
    Noop,
    RolledBack,
    CommitCompleted,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct RemoteSystemdRecoveryReport {
    pub report_version: u32,
    pub operation: String,
    pub transaction_id: Option<String>,
    pub unit: Option<String>,
    pub outcome: RemoteSystemdRecoveryOutcome,
    pub detail: String,
}

impl RemoteSystemdRecoveryReport {
    #[must_use]
    pub(crate) const fn exit_code(&self) -> i32 {
        match self.outcome {
            RemoteSystemdRecoveryOutcome::Deferred => 75,
            RemoteSystemdRecoveryOutcome::Noop
            | RemoteSystemdRecoveryOutcome::RolledBack
            | RemoteSystemdRecoveryOutcome::CommitCompleted => 0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RemoteSystemdUpgradeOutcome {
    Upgraded,
    Noop,
    RolledBack,
    RollbackFailed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct RemoteSystemdArtifact {
    pub version: String,
    pub sha256: String,
    pub binary_path: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct RemoteSystemdHealthReport {
    pub status: String,
    pub attempts: u64,
    pub main_pid: u32,
    pub n_restarts: u64,
    pub active_state: String,
    pub sub_state: String,
    pub observed_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct RemoteSystemdUpgradeReport {
    pub report_version: u32,
    pub operation: String,
    pub transaction_id: String,
    pub unit: String,
    pub outcome: RemoteSystemdUpgradeOutcome,
    pub changed: bool,
    pub previous: RemoteSystemdArtifact,
    pub candidate: RemoteSystemdArtifact,
    pub database_schema_before: Option<i64>,
    pub backup_path: Option<PathBuf>,
    pub failed_state_path: Option<PathBuf>,
    pub health: Option<RemoteSystemdHealthReport>,
    pub error: Option<String>,
    pub rollback_error: Option<String>,
}

impl RemoteSystemdUpgradeReport {
    #[must_use]
    pub(crate) const fn exit_code(&self) -> i32 {
        match self.outcome {
            RemoteSystemdUpgradeOutcome::Upgraded | RemoteSystemdUpgradeOutcome::Noop => 0,
            RemoteSystemdUpgradeOutcome::RolledBack => 1,
            RemoteSystemdUpgradeOutcome::RollbackFailed => 2,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct RemoteSystemdRollbackReport {
    pub report_version: u32,
    pub operation: String,
    pub transaction_id: String,
    pub unit: String,
    pub outcome: RemoteSystemdUpgradeOutcome,
    pub restored: RemoteSystemdArtifact,
    pub displaced: RemoteSystemdArtifact,
    pub database_schema_restored: Option<i64>,
    pub backup_path: PathBuf,
    pub health: Option<RemoteSystemdHealthReport>,
    pub error: Option<String>,
    pub recovery_error: Option<String>,
}

impl RemoteSystemdRollbackReport {
    #[must_use]
    pub(crate) const fn exit_code(&self) -> i32 {
        match self.outcome {
            RemoteSystemdUpgradeOutcome::Upgraded
            | RemoteSystemdUpgradeOutcome::Noop
            | RemoteSystemdUpgradeOutcome::RolledBack => 0,
            RemoteSystemdUpgradeOutcome::RollbackFailed => 2,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct GenerationManifest {
    pub(super) manifest_version: u32,
    pub(super) transaction_id: String,
    pub(super) unit: String,
    pub(super) created_at: String,
    pub(super) binary_path: PathBuf,
    pub(super) unit_path: PathBuf,
    pub(super) environment_path: PathBuf,
    pub(super) state_path: PathBuf,
    pub(super) binary_version: String,
    pub(super) binary_sha256: String,
    pub(super) unit_sha256: Option<String>,
    pub(super) environment_sha256: Option<String>,
    pub(super) state_sha256: Option<String>,
    pub(super) binary_metadata: FileMetadata,
    pub(super) unit_metadata: Option<FileMetadata>,
    pub(super) environment_metadata: Option<FileMetadata>,
    pub(super) state_present: bool,
    pub(super) database_present: bool,
    pub(super) database_schema: Option<i64>,
}

impl GenerationManifest {
    pub(super) fn artifact(&self) -> RemoteSystemdArtifact {
        RemoteSystemdArtifact {
            version: self.binary_version.clone(),
            sha256: self.binary_sha256.clone(),
            binary_path: self.binary_path.clone(),
        }
    }

    pub(super) fn validate_for(&self, plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
        if self.manifest_version != MANIFEST_VERSION {
            return Err(io_error(format!(
                "unsupported systemd rollback manifest version {}",
                self.manifest_version
            )));
        }
        if self.unit != plan.unit
            || self.binary_path != plan.binary_path
            || self.unit_path != plan.unit_path
            || self.environment_path != plan.environment_path
            || self.state_path != plan.state_path
        {
            return Err(io_error(format!(
                "rollback generation paths do not match unit {}",
                plan.unit
            )));
        }
        self.database_seal()?;
        Ok(())
    }

    pub(super) fn database_seal(&self) -> Result<DatabaseSeal, CliError> {
        let seal = DatabaseSeal::new(self.database_present, self.database_schema);
        seal.validate()?;
        Ok(seal)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct FileMetadata {
    pub(super) mode: u32,
    pub(super) uid: u32,
    pub(super) gid: u32,
}

impl FileMetadata {
    pub(super) fn read(path: &Path) -> Result<Self, CliError> {
        use std::os::unix::fs::MetadataExt as _;

        let metadata = regular_file_metadata(path)?;
        Ok(Self {
            mode: metadata.mode(),
            uid: metadata.uid(),
            gid: metadata.gid(),
        })
    }

    pub(super) fn private_executable() -> Self {
        // The command is root-only in production. Tests intentionally retain
        // the invoking user so the same transaction logic is testable there.
        Self {
            mode: 0o700,
            uid: uzers::get_current_uid(),
            gid: uzers::get_current_gid(),
        }
    }

    pub(super) const fn with_mode(mut self, mode: u32) -> Self {
        self.mode = mode;
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct SystemdObservation {
    pub(super) active_state: String,
    pub(super) sub_state: String,
    pub(super) main_pid: u32,
    pub(super) n_restarts: u64,
}

#[cfg(test)]
#[path = "model/tests.rs"]
mod tests;
