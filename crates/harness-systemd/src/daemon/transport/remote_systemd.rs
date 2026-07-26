use std::path::{Path, PathBuf};

use clap::Args;
use serde::Serialize;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};

use super::control::{print_json, running_controller_path};
use super::remote::DaemonRemoteServeArgs;
use super::remote_systemd_lifecycle::{CanonicalRemoteSystemdUnit, RemoteSystemdInstallReport};
use super::remote_systemd_lifecycle::{
    install_remote_systemd_with_pre_enable, preflight_remote_systemd_install, run_systemctl,
    uninstall_remote_systemd_with,
};
use super::remote_systemd_lifecycle::{
    parse_remote_systemd_unit_arg, preflight_uninstall_managed_binary,
    validate_canonical_unit_name, validate_path_outside_unit_directory,
    validate_systemd_directive_path,
};
use super::remote_systemd_upgrade_lifecycle::{
    BindMode, LockedLifecycle, RemoteSystemdUpgradeOutcome, RemoteSystemdUpgradeReport,
    adopt_existing_remote_systemd_unit, cleanup_recovery_artifacts,
    ensure_systemd_lifecycle_unarmed, remove_release_pair, upgrade_remote_systemd_claimed_with,
    verify_remote_systemd_health, verify_uninstall_controller,
};

#[path = "remote_systemd/credential_source.rs"]
mod credential_source;
#[path = "remote_systemd/unit_render.rs"]
mod unit_render;

use credential_source::validate_companion_credential_source;
#[cfg(test)]
pub(crate) use credential_source::validate_companion_credential_source_for_tests;
use unit_render::{render_env_file, render_unit, validate_systemd_exec_value};

const DEFAULT_UNIT: &str = "harness-remote-daemon";
const SYSTEMD_UNIT_DIR: &str = "/etc/systemd/system";
const SYSTEMD_ENV_DIR: &str = "/etc/harness";
const SYSTEMD_STATE_DIR: &str = "/var/lib";
const SYSTEMD_PRIVATE_STATE_DIR: &str = "/var/lib/private";
const SYSTEMD_TRANSACTION_DIR: &str = "/var/lib/harness/remote-systemd";

#[derive(Debug, Clone, Args)]
pub struct DaemonRemoteSystemdUnitArgs {
    /// systemd unit name.
    #[arg(long, default_value = DEFAULT_UNIT, value_parser = parse_remote_systemd_unit_arg)]
    pub unit: String,
}

#[derive(Debug, Clone, Args)]
pub struct DaemonRemoteSystemdArgs {
    /// systemd unit name.
    #[arg(long, default_value = DEFAULT_UNIT, value_parser = parse_remote_systemd_unit_arg)]
    pub unit: String,
    /// Path for the `EnvironmentFile` referenced by the service unit.
    #[arg(long)]
    pub env_file: Option<PathBuf>,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct DaemonRemoteSystemdInstallArgs {
    #[command(flatten)]
    pub serve: DaemonRemoteServeArgs,
    #[command(flatten)]
    pub systemd: DaemonRemoteSystemdUnitArgs,
    /// Explicit path to the `harness-daemon` binary. Defaults to the release-set sibling.
    #[arg(long)]
    pub binary_path: Option<PathBuf>,
    /// Path for the `EnvironmentFile` referenced by the service unit.
    #[arg(long)]
    pub env_file: Option<PathBuf>,
    /// Render and report the install plan without writing files or calling systemctl.
    #[arg(long)]
    pub dry_run: bool,
    /// Transactionally replace a drifted managed unit while preserving rollback state.
    #[arg(long)]
    pub reconfigure: bool,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
}

impl Execute for DaemonRemoteSystemdInstallArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let unit = CanonicalRemoteSystemdUnit::from_canonical(&self.systemd.unit)?;
        let binary = self.resolve_binary_path()?;
        let unit_path = unit.unit_path(Path::new(SYSTEMD_UNIT_DIR));
        let env_path = self
            .env_file
            .clone()
            .unwrap_or_else(|| unit.environment_path(Path::new(SYSTEMD_ENV_DIR)));
        let plan =
            RemoteSystemdInstallPlan::new(self, unit.into_string(), binary, unit_path, env_path)?;
        if let Some(source) = self.serve.companion_auth_token_file.as_deref() {
            validate_companion_credential_source(source)?;
        }

        if self.dry_run {
            print_install_response(
                &RemoteSystemdInstallResponse::dry_run(plan, self.reconfigure),
                self.json,
            )?;
            return Ok(0);
        }
        ensure_linux_systemd()?;
        super::remote_systemd_upgrade::ensure_root()?;
        if self.reconfigure {
            return self.execute_reconfigure(plan);
        }
        self.execute_install(plan)
    }
}

impl DaemonRemoteSystemdInstallArgs {
    fn execute_install(&self, plan: RemoteSystemdInstallPlan) -> Result<i32, CliError> {
        let transaction_root = Path::new(SYSTEMD_TRANSACTION_DIR);
        let store_path = transaction_root.join(&plan.unit);
        let locked = LockedLifecycle::acquire(transaction_root, &plan.unit, &store_path)?;
        ensure_systemd_lifecycle_unarmed(&store_path)?;
        let mut lifecycle =
            locked.bind(&plan.binary_path, BindMode::InstallOrMatch, &run_systemctl)?;
        let controller_path = running_controller_path()?;
        let mut persist_claim = || {
            lifecycle.persist_claim(&run_systemctl)?;
            lifecycle.establish_release_pair(&controller_path, &run_systemctl)
        };
        let report =
            install_remote_systemd_with_pre_enable(&plan, &run_systemctl, &mut persist_claim)?;
        print_install_response(
            &RemoteSystemdInstallResponse::applied(plan, report),
            self.json,
        )?;
        Ok(0)
    }

    fn execute_reconfigure(&self, plan: RemoteSystemdInstallPlan) -> Result<i32, CliError> {
        preflight_remote_systemd_install(&plan, &run_systemctl)?;
        let controller_path = running_controller_path()?;
        let upgrade_plan = super::remote_systemd_upgrade::reconfigure_upgrade_plan(
            &plan,
            controller_path.clone(),
        )?;
        let operation = &upgrade_plan.operation;
        let locked = LockedLifecycle::acquire(
            operation.transaction_root()?,
            &operation.unit,
            &operation.store_path,
        )?;
        ensure_systemd_lifecycle_unarmed(&operation.store_path)?;
        let mut lifecycle = locked.bind(
            &operation.binary_path,
            BindMode::InstallOrMatch,
            &run_systemctl,
        )?;
        adopt_existing_remote_systemd_unit(operation, &mut lifecycle, &run_systemctl)?;
        lifecycle.establish_release_pair(&controller_path, &run_systemctl)?;
        let report = upgrade_remote_systemd_claimed_with(
            &upgrade_plan,
            &lifecycle,
            &run_systemctl,
            &verify_remote_systemd_health,
        )?;
        let exit_code = report.exit_code();
        print_install_response(
            &RemoteSystemdInstallResponse::reconfigured(plan, report),
            self.json,
        )?;
        Ok(exit_code)
    }
}

impl DaemonRemoteSystemdArgs {
    /// Remove a remote daemon systemd unit and its environment file.
    ///
    /// # Errors
    /// Returns [`CliError`] when Linux systemd is unavailable or file removal fails.
    pub fn uninstall(&self, _context: &AppContext) -> Result<i32, CliError> {
        let unit = self.canonical_unit()?;
        let env_path = self.env_path(&unit);
        validate_systemd_directive_path("environment", &env_path)?;
        validate_path_outside_unit_directory(
            "environment",
            &env_path,
            Path::new(SYSTEMD_PRIVATE_STATE_DIR),
            unit.as_str(),
        )?;
        ensure_linux_systemd()?;
        super::remote_systemd_upgrade::ensure_root()?;
        let unit_path = unit.unit_path(Path::new(SYSTEMD_UNIT_DIR));
        let transaction_root = Path::new(SYSTEMD_TRANSACTION_DIR);
        let store_path = unit.child_path(transaction_root);
        let locked = LockedLifecycle::acquire(transaction_root, unit.as_str(), &store_path)?;
        ensure_systemd_lifecycle_unarmed(&store_path)?;
        let managed_binary = preflight_uninstall_managed_binary(&unit_path, &env_path)?;
        let existing_claim = locked.claim_for_unit()?;
        let claimed = match (managed_binary.as_deref(), existing_claim.as_ref()) {
            (Some(binary_path), Some(_)) => {
                Some(locked.bind(binary_path, BindMode::ExistingOnly, &run_systemctl)?)
            }
            (Some(binary_path), None) => {
                locked.validate_legacy_uninstall_binary(binary_path, &run_systemctl)?;
                None
            }
            (None, Some(claim)) => {
                let binary_path = claim.binary_path();
                let bind_mode = BindMode::ExistingOnly;
                let claimed = locked.bind(binary_path, bind_mode, &run_systemctl)?;
                Some(claimed)
            }
            (None, None) => None,
        };
        let controller_path = running_controller_path()?;
        verify_uninstall_controller(unit.as_str(), &controller_path, &store_path)?;
        cleanup_recovery_artifacts(unit.as_str(), &unit_path, &store_path, &run_systemctl)?;
        let report =
            uninstall_remote_systemd_with(unit.as_str(), &unit_path, &env_path, &run_systemctl)?;
        let _locked = match claimed {
            Some(claimed) => Some(claimed.remove_claim()?),
            None => None,
        };
        remove_release_pair(&store_path)?;
        if self.json {
            print_json(&report)?;
        } else if report.unit_removed || report.env_removed {
            println!("removed {}", unit.as_str());
        } else {
            println!("not installed");
        }
        Ok(0)
    }

    /// Show the current systemd status for the remote daemon unit.
    ///
    /// # Errors
    /// Returns [`CliError`] when Linux systemd is unavailable or status execution fails.
    pub fn status(&self, _context: &AppContext) -> Result<i32, CliError> {
        let unit = self.canonical_unit()?;
        ensure_linux_systemd()?;
        let output = run_systemctl(&["status".to_string(), unit.service_name()])?;
        let response = RemoteSystemdStatusResponse {
            unit: unit.as_str().to_string(),
            env_path: self.env_path(&unit),
            exit_code: output.exit_code,
            stdout: output.stdout,
            stderr: output.stderr,
        };
        if self.json {
            print_json(&response)?;
        } else {
            print!("{}", response.stdout);
            eprint!("{}", response.stderr);
        }
        Ok(response.exit_code)
    }
}

impl DaemonRemoteSystemdArgs {
    fn canonical_unit(&self) -> Result<CanonicalRemoteSystemdUnit, CliError> {
        CanonicalRemoteSystemdUnit::from_canonical(&self.unit)
    }

    fn env_path(&self, unit: &CanonicalRemoteSystemdUnit) -> PathBuf {
        self.env_file
            .clone()
            .unwrap_or_else(|| unit.environment_path(Path::new(SYSTEMD_ENV_DIR)))
    }
}

impl DaemonRemoteSystemdInstallArgs {
    fn resolve_binary_path(&self) -> Result<PathBuf, CliError> {
        self.binary_path.clone().map_or_else(
            || {
                harness_command::resolve_trusted_worker("harness-daemon", env!("CARGO_PKG_VERSION"))
                    .map_err(|error| {
                        CliError::from(CliErrorKind::workflow_io(format!(
                            "resolve sibling harness-daemon binary: {error}"
                        )))
                    })
            },
            Ok,
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RemoteSystemdInstallPlan {
    pub unit: String,
    pub binary_path: PathBuf,
    pub unit_path: PathBuf,
    pub env_path: PathBuf,
    pub unit_contents: String,
    pub env_contents: String,
    pub needs_bind_capability: bool,
    pub requires_systemd_credentials: bool,
}

impl RemoteSystemdInstallPlan {
    /// Build a validated install plan for production execution.
    ///
    /// # Errors
    /// Returns [`CliError`] when the remote serve contract is invalid or the unit is unsafe.
    pub(crate) fn new(
        args: &DaemonRemoteSystemdInstallArgs,
        unit: String,
        binary_path: PathBuf,
        unit_path: PathBuf,
        env_path: PathBuf,
    ) -> Result<Self, CliError> {
        validate_canonical_unit_name(&unit)?;
        let serve_config = args.serve.contract_config()?;
        validate_systemd_directive_path("binary", &binary_path)?;
        validate_systemd_directive_path("environment", &env_path)?;
        let dynamic_user_root = Path::new(SYSTEMD_PRIVATE_STATE_DIR);
        validate_path_outside_unit_directory("binary", &binary_path, dynamic_user_root, &unit)?;
        validate_path_outside_unit_directory("environment", &env_path, dynamic_user_root, &unit)?;
        validate_systemd_exec_value("domain", &serve_config.domain)?;
        validate_systemd_exec_value("host", &serve_config.host)?;
        validate_systemd_exec_value("acme email", &serve_config.acme_email)?;
        // Every value that reaches ExecStart needs this guard, not only the ones
        // that predate the companion flags.
        if let Some(companion) = serve_config.companion.as_ref() {
            validate_systemd_exec_value("companion upstream", &companion.upstream)?;
            validate_systemd_exec_value("companion path prefix", &companion.path_prefix)?;
            validate_companion_router_path(&companion.path_prefix)?;
            validate_systemd_directive_path(
                "companion credential source",
                &companion.auth_token_source,
            )?;
            validate_path_outside_unit_directory(
                "companion credential source",
                &companion.auth_token_source,
                dynamic_user_root,
                &unit,
            )?;
            validate_path_outside_unit_directory(
                "companion credential source",
                &companion.auth_token_source,
                Path::new(SYSTEMD_STATE_DIR),
                &unit,
            )?;
        }
        let needs_bind_capability = serve_config.https_port < 1024 || serve_config.http_port < 1024;
        let requires_systemd_credentials = serve_config.companion.is_some();
        let unit_contents = render_unit(
            &unit,
            &binary_path,
            &env_path,
            &serve_config,
            needs_bind_capability,
        );
        let env_contents = render_env_file(&unit);
        Ok(Self {
            unit,
            binary_path,
            unit_path,
            env_path,
            unit_contents,
            env_contents,
            needs_bind_capability,
            requires_systemd_credentials,
        })
    }

    #[cfg(test)]
    pub(crate) fn for_tests(
        args: &DaemonRemoteSystemdInstallArgs,
        binary_path: PathBuf,
        unit_path: PathBuf,
        env_path: PathBuf,
    ) -> Result<Self, CliError> {
        let unit = CanonicalRemoteSystemdUnit::from_canonical(&args.systemd.unit)?;
        Self::new(args, unit.into_string(), binary_path, unit_path, env_path)
    }
}

fn validate_companion_router_path(path: &str) -> Result<(), CliError> {
    if path.split('/').any(|segment| segment.starts_with(':')) {
        return Err(CliErrorKind::workflow_parse(format!(
            "systemd companion path prefix must not contain a segment starting with ':': {path}"
        ))
        .into());
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct RemoteSystemdInstallResponse {
    unit: String,
    unit_path: PathBuf,
    env_path: PathBuf,
    needs_bind_capability: bool,
    dry_run: bool,
    reconfigure: bool,
    applied: Option<RemoteSystemdInstallReport>,
    reconfigured: Option<RemoteSystemdUpgradeReport>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct RemoteSystemdStatusResponse {
    unit: String,
    env_path: PathBuf,
    exit_code: i32,
    stdout: String,
    stderr: String,
}

impl RemoteSystemdInstallResponse {
    fn dry_run(plan: RemoteSystemdInstallPlan, reconfigure: bool) -> Self {
        Self::from_plan(plan, true, reconfigure, None, None)
    }

    fn applied(plan: RemoteSystemdInstallPlan, report: RemoteSystemdInstallReport) -> Self {
        Self::from_plan(plan, false, false, Some(report), None)
    }

    fn reconfigured(plan: RemoteSystemdInstallPlan, report: RemoteSystemdUpgradeReport) -> Self {
        Self::from_plan(plan, false, true, None, Some(report))
    }

    fn from_plan(
        plan: RemoteSystemdInstallPlan,
        dry_run: bool,
        reconfigure: bool,
        applied: Option<RemoteSystemdInstallReport>,
        reconfigured: Option<RemoteSystemdUpgradeReport>,
    ) -> Self {
        Self {
            unit: plan.unit,
            unit_path: plan.unit_path,
            env_path: plan.env_path,
            needs_bind_capability: plan.needs_bind_capability,
            dry_run,
            reconfigure,
            applied,
            reconfigured,
        }
    }
}

fn print_install_response(
    response: &RemoteSystemdInstallResponse,
    json: bool,
) -> Result<(), CliError> {
    if json {
        print_json(response)?;
    } else if response.dry_run {
        if response.reconfigure {
            println!(
                "reconfigure {} transactionally",
                response.unit_path.display()
            );
        } else {
            println!("{}", response.unit_path.display());
        }
    } else if let Some(report) = response.reconfigured.as_ref() {
        match report.outcome {
            RemoteSystemdUpgradeOutcome::Upgraded => println!("reconfigured {}", response.unit),
            RemoteSystemdUpgradeOutcome::Noop => println!("already configured {}", response.unit),
            RemoteSystemdUpgradeOutcome::RolledBack => {
                println!("reconfigure rolled back {}", response.unit);
            }
            RemoteSystemdUpgradeOutcome::RollbackFailed => {
                println!("reconfigure rollback failed {}", response.unit);
            }
        }
    } else {
        println!("installed {}", response.unit);
    }
    Ok(())
}

pub(super) fn systemd_daemon_root(unit: &str) -> Result<PathBuf, CliError> {
    validate_canonical_unit_name(unit)?;
    Ok(Path::new(SYSTEMD_PRIVATE_STATE_DIR)
        .join(unit)
        .join("harness")
        .join("daemon")
        .join("external"))
}

#[cfg(test)]
pub(crate) fn default_env_path_for_tests(unit: &str) -> Result<PathBuf, CliError> {
    let unit = CanonicalRemoteSystemdUnit::parse(unit)?;
    Ok(unit.environment_path(Path::new(SYSTEMD_ENV_DIR)))
}

#[cfg(test)]
pub(crate) fn systemd_daemon_root_for_tests(unit: &str) -> Result<PathBuf, CliError> {
    let unit = CanonicalRemoteSystemdUnit::parse(unit)?;
    systemd_daemon_root(unit.as_str())
}

pub(super) fn ensure_linux_systemd() -> Result<(), CliError> {
    if cfg!(target_os = "linux") {
        Ok(())
    } else {
        Err(
            CliErrorKind::workflow_io("remote daemon systemd lifecycle requires Linux".to_string())
                .into(),
        )
    }
}
