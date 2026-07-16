use std::env::current_exe;
use std::path::{Path, PathBuf};

use clap::Args;
use serde::Serialize;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::remote::RemoteDaemonServeConfig;
use crate::errors::{CliError, CliErrorKind};

use super::control::print_json;
use super::remote::DaemonRemoteServeArgs;
use super::remote_systemd_lifecycle::{CanonicalRemoteSystemdUnit, RemoteSystemdInstallReport};
use super::remote_systemd_lifecycle::{
    install_remote_systemd_with_pre_enable, run_systemctl, uninstall_remote_systemd_with,
};
use super::remote_systemd_lifecycle::{
    parse_remote_systemd_unit_arg, preflight_uninstall_managed_binary,
    validate_canonical_unit_name, validate_path_outside_unit_directory,
    validate_systemd_directive_path,
};
use super::remote_systemd_upgrade_lifecycle::{
    BindMode, LockedLifecycle, cleanup_recovery_artifacts, ensure_systemd_lifecycle_unarmed,
};

const DEFAULT_UNIT: &str = "harness-remote-daemon";
const SYSTEMD_UNIT_DIR: &str = "/etc/systemd/system";
const SYSTEMD_ENV_DIR: &str = "/etc/harness";
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
    /// Explicit path to the `harness-daemon` binary. Defaults to the current executable.
    #[arg(long)]
    pub binary_path: Option<PathBuf>,
    /// Path for the `EnvironmentFile` referenced by the service unit.
    #[arg(long)]
    pub env_file: Option<PathBuf>,
    /// Render and report the install plan without writing files or calling systemctl.
    #[arg(long)]
    pub dry_run: bool,
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

        if self.dry_run {
            print_install_response(&RemoteSystemdInstallResponse::dry_run(plan), self.json)?;
            return Ok(0);
        }
        ensure_linux_systemd()?;
        super::remote_systemd_upgrade::ensure_root()?;
        let transaction_root = Path::new(SYSTEMD_TRANSACTION_DIR);
        let store_path = transaction_root.join(&plan.unit);
        let locked = LockedLifecycle::acquire(transaction_root, &plan.unit, &store_path)?;
        ensure_systemd_lifecycle_unarmed(&store_path)?;
        let mut lifecycle =
            locked.bind(&plan.binary_path, BindMode::InstallOrMatch, &run_systemctl)?;
        let mut persist_claim = || lifecycle.persist_claim(&run_systemctl);
        let report =
            install_remote_systemd_with_pre_enable(&plan, &run_systemctl, &mut persist_claim)?;
        print_install_response(
            &RemoteSystemdInstallResponse::applied(plan, report),
            self.json,
        )?;
        Ok(0)
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
        cleanup_recovery_artifacts(unit.as_str(), &unit_path, &store_path, &run_systemctl)?;
        let report =
            uninstall_remote_systemd_with(unit.as_str(), &unit_path, &env_path, &run_systemctl)?;
        if let Some(claimed) = claimed {
            let _locked = claimed.remove_claim()?;
        }
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
                current_exe().map_err(|error| {
                    CliError::from(CliErrorKind::workflow_io(format!(
                        "resolve current harness-daemon binary: {error}"
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
        let needs_bind_capability = serve_config.https_port < 1024 || serve_config.http_port < 1024;
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct RemoteSystemdInstallResponse {
    unit: String,
    unit_path: PathBuf,
    env_path: PathBuf,
    needs_bind_capability: bool,
    dry_run: bool,
    applied: Option<RemoteSystemdInstallReport>,
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
    fn dry_run(plan: RemoteSystemdInstallPlan) -> Self {
        Self::from_plan(plan, true, None)
    }

    fn applied(plan: RemoteSystemdInstallPlan, report: RemoteSystemdInstallReport) -> Self {
        Self::from_plan(plan, false, Some(report))
    }

    fn from_plan(
        plan: RemoteSystemdInstallPlan,
        dry_run: bool,
        applied: Option<RemoteSystemdInstallReport>,
    ) -> Self {
        Self {
            unit: plan.unit,
            unit_path: plan.unit_path,
            env_path: plan.env_path,
            needs_bind_capability: plan.needs_bind_capability,
            dry_run,
            applied,
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
        println!("{}", response.unit_path.display());
    } else {
        println!("installed {}", response.unit);
    }
    Ok(())
}

fn render_unit(
    unit: &str,
    binary_path: &Path,
    env_path: &Path,
    serve_config: &RemoteDaemonServeConfig,
    needs_bind_capability: bool,
) -> String {
    let exec_start = render_systemd_exec_start(&remote_serve_command(binary_path, serve_config));
    let mut contents = format!(
        "[Unit]\n\
         Description=Harness remote daemon\n\
         After=network-online.target\n\
         Wants=network-online.target\n\
         \n\
         [Service]\n\
         Type=notify\n\
         NotifyAccess=main\n\
         TimeoutStartSec=20min\n\
         KillMode=control-group\n\
         EnvironmentFile={}\n\
         Environment=HARNESS_DAEMON_DATA_HOME=%S/{unit}\n\
         Environment=XDG_DATA_HOME=%S/{unit}\n\
         Environment=HARNESS_DAEMON_OWNERSHIP=external\n\
         ExecStart={exec_start}\n\
         Restart=on-failure\n\
         RestartSec=5s\n\
         NoNewPrivileges=true\n\
         DynamicUser=yes\n\
         PrivateTmp=true\n\
         PrivateDevices=true\n\
         PrivateMounts=true\n\
         ProtectSystem=strict\n\
         ProtectHome=true\n\
         ProtectClock=true\n\
         ProtectControlGroups=true\n\
         ProtectHostname=true\n\
         ProtectKernelLogs=true\n\
         ProtectKernelModules=true\n\
         ProtectKernelTunables=true\n\
         ProtectProc=invisible\n\
         ProcSubset=pid\n\
         LockPersonality=true\n\
         MemoryDenyWriteExecute=true\n\
         RestrictNamespaces=true\n\
         RestrictRealtime=true\n\
         RestrictSUIDSGID=true\n\
         RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX\n\
         SystemCallArchitectures=native\n\
         SystemCallFilter=@system-service\n\
         SystemCallFilter=~@privileged @resources\n\
         SystemCallErrorNumber=EPERM\n\
         StateDirectory={unit}\n\
         StateDirectoryMode=0700\n\
         UMask=0077\n",
        env_path.display()
    );
    if needs_bind_capability {
        contents.push_str(
            "AmbientCapabilities=CAP_NET_BIND_SERVICE\n\
             CapabilityBoundingSet=CAP_NET_BIND_SERVICE\n",
        );
    } else {
        contents.push_str(
            "CapabilityBoundingSet=\n\
             PrivateUsers=true\n",
        );
    }
    contents.push_str("\n[Install]\nWantedBy=multi-user.target\n");
    contents
}

fn remote_serve_command(binary_path: &Path, config: &RemoteDaemonServeConfig) -> Vec<String> {
    let mut command = vec![
        binary_path.display().to_string(),
        "remote".to_string(),
        "serve".to_string(),
        "--domain".to_string(),
        config.domain.clone(),
        "--host".to_string(),
        config.host.clone(),
        "--https-port".to_string(),
        config.https_port.to_string(),
        "--http-port".to_string(),
        config.http_port.to_string(),
        "--acme-email".to_string(),
        config.acme_email.clone(),
        "--acme-challenge".to_string(),
        config.acme_challenge.as_str().to_string(),
    ];
    if let Some(provider) = config.acme_dns_provider {
        command.push("--acme-dns-provider".to_string());
        command.push(provider.as_str().to_string());
    }
    command
}

fn validate_systemd_exec_value(label: &str, value: &str) -> Result<(), CliError> {
    if value.chars().any(char::is_control) {
        return Err(CliErrorKind::workflow_parse(format!(
            "systemd {label} contains control characters"
        ))
        .into());
    }
    Ok(())
}

fn render_systemd_exec_start(command: &[String]) -> String {
    command
        .iter()
        .map(|argument| render_systemd_exec_argument(argument))
        .collect::<Vec<_>>()
        .join(" ")
}

fn render_systemd_exec_argument(argument: &str) -> String {
    if !argument.is_empty() && argument.chars().all(is_systemd_bare_exec_char) {
        return argument.to_string();
    }
    let mut quoted = String::with_capacity(argument.len() + 2);
    quoted.push('"');
    for character in argument.chars() {
        match character {
            '"' | '\\' => {
                quoted.push('\\');
                quoted.push(character);
            }
            '%' => quoted.push_str("%%"),
            _ => quoted.push(character),
        }
    }
    quoted.push('"');
    quoted
}

fn is_systemd_bare_exec_char(character: char) -> bool {
    !character.is_whitespace() && !matches!(character, '"' | '%' | '\'' | '\\')
}

fn render_env_file(unit: &str) -> String {
    format!("# harness remote daemon environment for {unit}\n")
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
