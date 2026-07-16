use std::env::current_exe;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use clap::Args;
use serde::Serialize;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};

use super::control::print_json;
use super::remote_systemd::{
    DaemonRemoteSystemdUnitArgs, ensure_linux_systemd, systemd_daemon_root,
};
use super::remote_systemd_lifecycle::{
    CanonicalRemoteSystemdUnit, run_systemctl, unit_service_name,
};
use super::remote_systemd_upgrade_lifecycle::{
    RemoteSystemdOperationPlan, RemoteSystemdRecoveryReport, RemoteSystemdRollbackReport,
    RemoteSystemdUpgradePlan, RemoteSystemdUpgradeReport, recover_remote_systemd_with,
    rollback_remote_systemd_with, upgrade_remote_systemd_with, verify_remote_systemd_health,
};

const DEFAULT_INSTALLED_BINARY: &str = "/usr/local/bin/harness-daemon";
const DEFAULT_SYSTEMD_UNIT_DIR: &str = "/etc/systemd/system";
const DEFAULT_SYSTEMD_ENV_DIR: &str = "/etc/harness";
const DEFAULT_TRANSACTION_ROOT: &str = "/var/lib/harness/remote-systemd";
const DEFAULT_READINESS_TIMEOUT_SECONDS: u64 = 180;
const DEFAULT_STABILIZATION_WINDOW_SECONDS: u64 = 15;

#[derive(Debug, Clone, Args)]
pub struct DaemonRemoteSystemdUpgradeArgs {
    #[command(flatten)]
    pub systemd: DaemonRemoteSystemdUnitArgs,
    /// New harness-daemon executable. Omission performs a same-binary health check.
    #[arg(long)]
    pub candidate_path: Option<PathBuf>,
    /// Installed executable referenced by the systemd unit.
    #[arg(long, default_value = DEFAULT_INSTALLED_BINARY)]
    pub binary_path: PathBuf,
    /// Environment file referenced by the systemd unit.
    #[arg(long)]
    pub env_file: Option<PathBuf>,
    /// Maximum time to wait for systemd readiness.
    #[arg(long, default_value_t = DEFAULT_READINESS_TIMEOUT_SECONDS)]
    pub readiness_timeout_seconds: u64,
    /// Time the ready process must remain stable without a restart.
    #[arg(long, default_value_t = DEFAULT_STABILIZATION_WINDOW_SECONDS)]
    pub stabilization_window_seconds: u64,
    /// Show the transaction paths without stopping or changing the service.
    #[arg(long)]
    pub dry_run: bool,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct DaemonRemoteSystemdRollbackArgs {
    #[command(flatten)]
    pub systemd: DaemonRemoteSystemdUnitArgs,
    /// Installed executable referenced by the systemd unit.
    #[arg(long, default_value = DEFAULT_INSTALLED_BINARY)]
    pub binary_path: PathBuf,
    /// Environment file referenced by the systemd unit.
    #[arg(long)]
    pub env_file: Option<PathBuf>,
    /// Confirm that restoring the previous database discards newer writes.
    #[arg(long)]
    pub confirm_data_loss: bool,
    /// Maximum time to wait for systemd readiness.
    #[arg(long, default_value_t = DEFAULT_READINESS_TIMEOUT_SECONDS)]
    pub readiness_timeout_seconds: u64,
    /// Time the restored process must remain stable without a restart.
    #[arg(long, default_value_t = DEFAULT_STABILIZATION_WINDOW_SECONDS)]
    pub stabilization_window_seconds: u64,
    /// Show the retained generation without changing the service.
    #[arg(long)]
    pub dry_run: bool,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct DaemonRemoteSystemdRecoverArgs {
    /// Durable transaction store containing the recovery arm.
    #[arg(long)]
    pub store_path: PathBuf,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
}

impl Execute for DaemonRemoteSystemdUpgradeArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let plan = self.plan()?;
        if self.dry_run {
            print_upgrade_plan(&plan, self.json)?;
            return Ok(0);
        }
        ensure_linux_systemd()?;
        ensure_root()?;
        let report =
            upgrade_remote_systemd_with(&plan, &run_systemctl, &verify_remote_systemd_health)?;
        print_upgrade_report(&report, self.json)?;
        Ok(report.exit_code())
    }
}

impl Execute for DaemonRemoteSystemdRollbackArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let plan = self.plan()?;
        if self.dry_run {
            print_rollback_plan(&plan, self.json)?;
            return Ok(0);
        }
        if !self.confirm_data_loss {
            return Err(CliErrorKind::workflow_parse(
                "rollback-systemd requires --confirm-data-loss because it restores the previous database and discards newer writes"
                    .to_string(),
            )
            .into());
        }
        ensure_linux_systemd()?;
        ensure_root()?;
        let report =
            rollback_remote_systemd_with(&plan, &run_systemctl, &verify_remote_systemd_health)?;
        print_rollback_report(&report, self.json)?;
        Ok(report.exit_code())
    }
}

impl Execute for DaemonRemoteSystemdRecoverArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let store_path = validated_recovery_store_path(&self.store_path)?;
        ensure_linux_systemd()?;
        ensure_root()?;
        let report = recover_remote_systemd_with(
            &store_path,
            &run_systemctl,
            &verify_remote_systemd_health,
        )?;
        print_recovery_report(&report, self.json)?;
        Ok(report.exit_code())
    }
}

impl DaemonRemoteSystemdUpgradeArgs {
    fn plan(&self) -> Result<RemoteSystemdUpgradePlan, CliError> {
        let operation = operation_plan(
            &self.systemd.unit,
            &self.binary_path,
            self.env_file.as_deref(),
            self.readiness_timeout_seconds,
            self.stabilization_window_seconds,
            Path::new(DEFAULT_TRANSACTION_ROOT),
        )?;
        let candidate_path = self.candidate_path.clone().map_or_else(
            || {
                current_exe().map_err(|error| {
                    CliError::from(CliErrorKind::workflow_io(format!(
                        "resolve current harness executable: {error}"
                    )))
                })
            },
            Ok,
        )?;
        let candidate_path = absolute_path(&candidate_path)?;
        Ok(RemoteSystemdUpgradePlan {
            operation,
            candidate_path,
        })
    }
}

impl DaemonRemoteSystemdRollbackArgs {
    fn plan(&self) -> Result<RemoteSystemdOperationPlan, CliError> {
        operation_plan(
            &self.systemd.unit,
            &self.binary_path,
            self.env_file.as_deref(),
            self.readiness_timeout_seconds,
            self.stabilization_window_seconds,
            Path::new(DEFAULT_TRANSACTION_ROOT),
        )
    }
}

fn operation_plan(
    unit: &str,
    binary_path: &Path,
    environment_path: Option<&Path>,
    readiness_timeout_seconds: u64,
    stabilization_window_seconds: u64,
    transaction_root: &Path,
) -> Result<RemoteSystemdOperationPlan, CliError> {
    let unit = CanonicalRemoteSystemdUnit::from_canonical(unit)?;
    let daemon_root = systemd_daemon_root(unit.as_str())?;
    let state_path = daemon_root
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "derive systemd state path from {}",
                daemon_root.display()
            )))
        })?
        .to_path_buf();
    let binary_path = absolute_path(binary_path)?;
    let environment_path = environment_path.map_or_else(
        || Ok(unit.environment_path(Path::new(DEFAULT_SYSTEMD_ENV_DIR))),
        absolute_path,
    )?;
    let plan = RemoteSystemdOperationPlan {
        unit: unit.as_str().to_string(),
        binary_path,
        unit_path: unit.unit_path(Path::new(DEFAULT_SYSTEMD_UNIT_DIR)),
        environment_path,
        state_path,
        store_path: unit.child_path(transaction_root),
        controller_path: PathBuf::from("/proc/self/exe"),
        readiness_timeout: Duration::from_secs(readiness_timeout_seconds),
        stabilization_window: Duration::from_secs(stabilization_window_seconds),
    };
    plan.validate()?;
    Ok(plan)
}

fn absolute_path(path: &Path) -> Result<PathBuf, CliError> {
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        Err(CliErrorKind::workflow_parse(format!(
            "systemd operation path must be absolute: {}",
            path.display()
        ))
        .into())
    }
}

fn validated_recovery_store_path(path: &Path) -> Result<PathBuf, CliError> {
    let path = absolute_path(path)?;
    let root = Path::new(DEFAULT_TRANSACTION_ROOT);
    let relative = path.strip_prefix(root).map_err(|_| {
        CliError::from(CliErrorKind::workflow_parse(format!(
            "systemd recovery store must be one unit below {}: {}",
            root.display(),
            path.display()
        )))
    })?;
    let mut components = relative.components();
    let Some(Component::Normal(unit)) = components.next() else {
        return Err(CliErrorKind::workflow_parse(format!(
            "systemd recovery store must name one unit below {}",
            root.display()
        ))
        .into());
    };
    if components.next().is_some() {
        return Err(CliErrorKind::workflow_parse(format!(
            "systemd recovery store must not contain nested paths: {}",
            path.display()
        ))
        .into());
    }
    let unit = unit.to_str().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_parse(
            "systemd recovery unit must be valid UTF-8".to_string(),
        ))
    })?;
    CanonicalRemoteSystemdUnit::from_canonical(unit)?;
    Ok(path)
}

#[cfg(test)]
pub(crate) fn validated_recovery_store_path_for_tests(path: &Path) -> Result<PathBuf, CliError> {
    validated_recovery_store_path(path)
}

pub(super) fn ensure_root() -> Result<(), CliError> {
    if uzers::get_current_uid() == 0 {
        Ok(())
    } else {
        Err(CliErrorKind::workflow_io(
            "remote systemd upgrade and rollback require root".to_string(),
        )
        .into())
    }
}

#[derive(Debug, Serialize)]
struct RemoteSystemdOperationPlanResponse<'a> {
    report_version: u32,
    operation: &'static str,
    dry_run: bool,
    unit: &'a str,
    service: String,
    candidate_path: Option<&'a Path>,
    binary_path: &'a Path,
    unit_path: &'a Path,
    environment_path: &'a Path,
    state_path: &'a Path,
    transaction_store: &'a Path,
    previous_generation: PathBuf,
}

fn print_upgrade_plan(plan: &RemoteSystemdUpgradePlan, json: bool) -> Result<(), CliError> {
    let response = operation_plan_response(
        "upgrade_systemd",
        &plan.operation,
        Some(&plan.candidate_path),
    );
    if json {
        print_json(&response)
    } else {
        println!(
            "upgrade {} from {} to {} (state snapshot: {})",
            response.service,
            response.candidate_path.map_or_else(
                || "<current executable>".to_string(),
                |path| path.display().to_string()
            ),
            response.binary_path.display(),
            response.previous_generation.display()
        );
        Ok(())
    }
}

fn print_rollback_plan(plan: &RemoteSystemdOperationPlan, json: bool) -> Result<(), CliError> {
    let response = operation_plan_response("rollback_systemd", plan, None);
    if json {
        print_json(&response)
    } else {
        println!(
            "rollback {} from {} (database and state included)",
            response.service,
            response.previous_generation.display()
        );
        Ok(())
    }
}

fn operation_plan_response<'a>(
    operation: &'static str,
    plan: &'a RemoteSystemdOperationPlan,
    candidate_path: Option<&'a Path>,
) -> RemoteSystemdOperationPlanResponse<'a> {
    RemoteSystemdOperationPlanResponse {
        report_version: 1,
        operation,
        dry_run: true,
        unit: &plan.unit,
        service: unit_service_name(&plan.unit),
        candidate_path,
        binary_path: &plan.binary_path,
        unit_path: &plan.unit_path,
        environment_path: &plan.environment_path,
        state_path: &plan.state_path,
        transaction_store: &plan.store_path,
        previous_generation: plan.store_path.join("previous"),
    }
}

fn print_upgrade_report(report: &RemoteSystemdUpgradeReport, json: bool) -> Result<(), CliError> {
    if json {
        print_json(report)
    } else {
        println!(
            "{} {} ({:?})",
            report.operation, report.unit, report.outcome
        );
        if let Some(error) = &report.error {
            println!("upgrade failure: {error}");
        }
        if let Some(error) = &report.rollback_error {
            println!("rollback failure: {error}");
        }
        Ok(())
    }
}

fn print_rollback_report(report: &RemoteSystemdRollbackReport, json: bool) -> Result<(), CliError> {
    if json {
        print_json(report)
    } else {
        println!(
            "{} {} ({:?})",
            report.operation, report.unit, report.outcome
        );
        if let Some(error) = &report.error {
            println!("rollback failure: {error}");
        }
        if let Some(error) = &report.recovery_error {
            println!("recovery failure: {error}");
        }
        Ok(())
    }
}

fn print_recovery_report(report: &RemoteSystemdRecoveryReport, json: bool) -> Result<(), CliError> {
    if json {
        print_json(report)
    } else {
        println!(
            "{} ({:?}): {}",
            report.operation, report.outcome, report.detail
        );
        Ok(())
    }
}
