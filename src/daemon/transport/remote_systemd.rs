use std::env::current_exe;
use std::path::{Path, PathBuf};

use clap::Args;
use serde::Serialize;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::remote::RemoteDaemonServeConfig;
use crate::errors::{CliError, CliErrorKind};

use super::control::print_json;
use super::remote::DaemonRemoteServeArgs;
use super::remote_systemd_lifecycle::{
    RemoteSystemdInstallReport, install_remote_systemd_with, normalize_unit_name, run_systemctl,
    unit_service_name, uninstall_remote_systemd_with, validate_unit_name,
};

const DEFAULT_UNIT: &str = "harness-remote-daemon";
const SYSTEMD_UNIT_DIR: &str = "/etc/systemd/system";
const SYSTEMD_ENV_DIR: &str = "/etc/harness";

#[derive(Debug, Clone, Args)]
pub struct DaemonRemoteSystemdUnitArgs {
    /// systemd unit name.
    #[arg(long, default_value = DEFAULT_UNIT)]
    pub unit: String,
}

#[derive(Debug, Clone, Args)]
pub struct DaemonRemoteSystemdArgs {
    /// systemd unit name.
    #[arg(long, default_value = DEFAULT_UNIT)]
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
    /// Explicit path to the harness binary. Defaults to the current executable.
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
        let binary = self.resolve_binary_path()?;
        let unit_path = default_unit_path(&self.systemd.unit);
        let env_path = self
            .env_file
            .clone()
            .unwrap_or_else(|| default_env_path(&self.systemd.unit));
        let plan = RemoteSystemdInstallPlan::new(self, binary, unit_path, env_path)?;

        if self.dry_run {
            print_install_response(&RemoteSystemdInstallResponse::dry_run(plan), self.json)?;
            return Ok(0);
        }
        ensure_linux_systemd()?;

        let report = install_remote_systemd_with(&plan, &run_systemctl)?;
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
        ensure_linux_systemd()?;
        let unit_path = default_unit_path(&self.unit);
        let env_path = self.env_path();
        let report =
            uninstall_remote_systemd_with(&self.unit, &unit_path, &env_path, &run_systemctl)?;
        if self.json {
            print_json(&report)?;
        } else if report.unit_removed || report.env_removed {
            println!("removed {}", self.unit);
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
        self.validate()?;
        ensure_linux_systemd()?;
        let output = run_systemctl(&["status".to_string(), unit_service_name(&self.unit)])?;
        let response = RemoteSystemdStatusResponse {
            unit: self.unit.clone(),
            env_path: self.env_path(),
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
    fn validate(&self) -> Result<(), CliError> {
        validate_unit_name(&self.unit)
    }

    fn env_path(&self) -> PathBuf {
        self.env_file
            .clone()
            .unwrap_or_else(|| default_env_path(&self.unit))
    }

    #[cfg(test)]
    pub(crate) fn validate_for_tests(&self) -> Result<(), CliError> {
        self.validate()
    }
}

impl DaemonRemoteSystemdInstallArgs {
    fn resolve_binary_path(&self) -> Result<PathBuf, CliError> {
        self.binary_path.clone().map_or_else(
            || {
                current_exe().map_err(|error| {
                    CliError::from(CliErrorKind::workflow_io(format!(
                        "resolve current harness binary: {error}"
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
        binary_path: PathBuf,
        unit_path: PathBuf,
        env_path: PathBuf,
    ) -> Result<Self, CliError> {
        let unit = normalize_unit_name(&args.systemd.unit);
        validate_unit_name(unit)?;
        let serve_config = args.serve.contract_config()?;
        validate_systemd_directive_path("binary", &binary_path)?;
        validate_systemd_directive_path("environment", &env_path)?;
        validate_systemd_exec_value("domain", &serve_config.domain)?;
        validate_systemd_exec_value("host", &serve_config.host)?;
        validate_systemd_exec_value("acme email", &serve_config.acme_email)?;
        let needs_bind_capability = serve_config.https_port < 1024 || serve_config.http_port < 1024;
        let unit_contents = render_unit(
            unit,
            &binary_path,
            &env_path,
            &serve_config,
            needs_bind_capability,
        );
        let env_contents = render_env_file(unit);
        Ok(Self {
            unit: unit.to_string(),
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
        Self::new(args, binary_path, unit_path, env_path)
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
         Type=simple\n\
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
         ProtectSystem=strict\n\
         ProtectHome=true\n\
         RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX\n\
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
    }
    contents.push_str("\n[Install]\nWantedBy=multi-user.target\n");
    contents
}

fn remote_serve_command(binary_path: &Path, config: &RemoteDaemonServeConfig) -> Vec<String> {
    let mut command = vec![
        binary_path.display().to_string(),
        "daemon".to_string(),
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

fn validate_systemd_directive_path(label: &str, path: &Path) -> Result<(), CliError> {
    let rendered = path.as_os_str().to_string_lossy();
    if !path.is_absolute() {
        return Err(CliErrorKind::workflow_parse(format!(
            "systemd {label} path must be absolute: {}",
            path.display()
        ))
        .into());
    }
    if rendered.chars().any(char::is_whitespace) {
        return Err(CliErrorKind::workflow_parse(format!(
            "systemd {label} path contains whitespace: {}",
            path.display()
        ))
        .into());
    }
    if rendered.contains('%') {
        return Err(CliErrorKind::workflow_parse(format!(
            "systemd {label} path cannot contain '%': {}",
            path.display()
        ))
        .into());
    }
    Ok(())
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

fn default_unit_path(unit: &str) -> PathBuf {
    Path::new(SYSTEMD_UNIT_DIR).join(unit_service_name(unit))
}

fn default_env_path(unit: &str) -> PathBuf {
    let unit = normalize_unit_name(unit);
    Path::new(SYSTEMD_ENV_DIR).join(format!("{unit}.env"))
}

#[cfg(test)]
pub(crate) fn default_env_path_for_tests(unit: &str) -> PathBuf {
    default_env_path(unit)
}

fn ensure_linux_systemd() -> Result<(), CliError> {
    if cfg!(target_os = "linux") {
        Ok(())
    } else {
        Err(
            CliErrorKind::workflow_io("remote daemon systemd lifecycle requires Linux".to_string())
                .into(),
        )
    }
}
