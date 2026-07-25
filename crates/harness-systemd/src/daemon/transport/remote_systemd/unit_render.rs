//! Rendering the remote daemon's systemd unit and environment file.
//!
//! Everything the installed unit says about the daemon is produced here, so the
//! serve command line and the hardening directives stay in one place. The
//! installer refuses a unit on disk that differs from what this renders, which
//! is why a new serve flag has to be added to [`remote_serve_command`] rather
//! than to an operator's copy of the unit.

use std::path::Path;

use crate::daemon::remote::RemoteDaemonServeConfig;
use crate::errors::{CliError, CliErrorKind};

pub(super) fn render_unit(
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
    if let Some(companion) = config.companion.as_ref() {
        command.push("--companion-upstream".to_string());
        command.push(companion.upstream.clone());
        command.push("--companion-path-prefix".to_string());
        command.push(companion.path_prefix.clone());
    }
    command
}

pub(super) fn validate_systemd_exec_value(label: &str, value: &str) -> Result<(), CliError> {
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

pub(super) fn render_env_file(unit: &str) -> String {
    format!("# harness remote daemon environment for {unit}\n")
}
