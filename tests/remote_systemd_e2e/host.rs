use std::ffi::OsStr;
use std::fs;
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::Value;
use tempfile::TempDir;

pub struct RemoteSystemdHost {
    _temp: TempDir,
    unit: String,
    service: String,
    domain: String,
    binary_source: PathBuf,
    binary_path: PathBuf,
    unit_path: PathBuf,
    env_path: PathBuf,
    ca_path: PathBuf,
    state_path: PathBuf,
    fake_ca_root: PathBuf,
    dns_log: PathBuf,
    https_port: u16,
    http_port: u16,
}

impl RemoteSystemdHost {
    pub fn new(domain: &str) -> Result<Self, String> {
        let temp = tempfile::Builder::new()
            .prefix("harness-remote-systemd-e2e-")
            .tempdir()
            .map_err(|error| format!("create systemd e2e tempdir: {error}"))?;
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|error| format!("read system clock: {error}"))?
            .as_nanos();
        let unit = format!("harness-remote-e2e-{}-{nonce}", std::process::id());
        let (https_port, http_port) = available_low_port_pair()?;
        Ok(Self {
            binary_source: assert_cmd::cargo::cargo_bin("harness"),
            binary_path: PathBuf::from(format!("/usr/local/libexec/{unit}")),
            unit_path: PathBuf::from(format!("/etc/systemd/system/{unit}.service")),
            env_path: PathBuf::from(format!("/etc/harness/{unit}.env")),
            ca_path: PathBuf::from(format!("/etc/harness/{unit}-ca.pem")),
            state_path: PathBuf::from(format!("/var/lib/private/{unit}")),
            fake_ca_root: temp.path().join("fake-acme-ca.pem"),
            dns_log: temp.path().join("dns-hook.log"),
            service: format!("{unit}.service"),
            domain: domain.to_string(),
            unit,
            https_port,
            http_port,
            _temp: temp,
        })
    }

    pub fn assert_prerequisites(&self) -> Result<(), String> {
        if !Path::new("/run/systemd/system").is_dir() {
            return Err("systemd is not PID 1 on this Linux host".to_string());
        }
        checked(command("systemd-analyze", ["--version"]), "inspect systemd")?;
        checked(sudo(["true"]), "verify passwordless sudo")?;
        let output = checked(
            command("sysctl", ["-n", "net.ipv4.ip_unprivileged_port_start"]),
            "read unprivileged port floor",
        )?;
        let floor = stdout(&output, "unprivileged port floor")?
            .trim()
            .parse::<u16>()
            .map_err(|error| format!("parse unprivileged port floor: {error}"))?;
        if floor <= self.https_port || floor <= self.http_port {
            return Err(format!(
                "host permits unprivileged binds below test ports: floor={floor}"
            ));
        }
        Ok(())
    }

    pub const fn https_port(&self) -> u16 {
        self.https_port
    }

    pub const fn http_port(&self) -> u16 {
        self.http_port
    }

    pub fn fake_ca_root(&self) -> &Path {
        &self.fake_ca_root
    }

    pub fn dns_log(&self) -> &Path {
        &self.dns_log
    }

    pub fn prepare(&self, directory_url: &str, ca_pem: &str) -> Result<(), String> {
        self.cleanup();
        checked(
            sudo([
                "install",
                "-d",
                "-m",
                "0755",
                "/usr/local/libexec",
                "/etc/harness",
            ]),
            "create systemd e2e install directories",
        )?;
        install_file(&self.binary_source, &self.binary_path, "0755")?;
        let ca_source = self.fake_ca_root.with_file_name("installed-ca.pem");
        fs::write(&ca_source, ca_pem)
            .map_err(|error| format!("write systemd e2e CA source: {error}"))?;
        install_file(&ca_source, &self.ca_path, "0644")?;
        let env_source = self.fake_ca_root.with_file_name("remote.env");
        let env = format!(
            "HARNESS_REMOTE_ACME_DIRECTORY_URL={directory_url}\nHARNESS_REMOTE_ACME_CA_ROOT={}\nRUST_LOG=harness=debug\n",
            self.ca_path.display()
        );
        fs::write(&env_source, env)
            .map_err(|error| format!("write systemd e2e environment source: {error}"))?;
        install_file(&env_source, &self.env_path, "0600")
    }

    pub fn install(&self) -> Result<Value, String> {
        let mut command = sudo([self.binary_path.as_os_str()]);
        command.args([
            "daemon",
            "remote",
            "install-systemd",
            "--unit",
            &self.unit,
            "--domain",
            &self.domain,
            "--host",
            "127.0.0.1",
            "--acme-email",
            "systemd-e2e@example.com",
            "--acme-challenge",
            "tls-alpn",
            "--json",
        ]);
        command
            .arg("--https-port")
            .arg(self.https_port.to_string())
            .arg("--http-port")
            .arg(self.http_port.to_string())
            .arg("--binary-path")
            .arg(&self.binary_path)
            .arg("--env-file")
            .arg(&self.env_path);
        json_output(command, "install remote systemd unit")
    }

    pub fn uninstall(&self) -> Result<Value, String> {
        let mut command = sudo([self.binary_path.as_os_str()]);
        command.args([
            "daemon",
            "remote",
            "uninstall-systemd",
            "--unit",
            &self.unit,
            "--json",
        ]);
        command.arg("--env-file").arg(&self.env_path);
        json_output(command, "uninstall remote systemd unit")
    }

    pub fn create_pairing(&self, role: &str) -> Result<Value, String> {
        let mut command = sudo(["env"]);
        command
            .arg(format!("HOME={}", self.state_path.display()))
            .arg(format!("XDG_DATA_HOME={}", self.state_path.display()))
            .arg(format!(
                "HARNESS_DAEMON_DATA_HOME={}",
                self.state_path.display()
            ))
            .arg("HARNESS_DAEMON_OWNERSHIP=external")
            .arg(&self.binary_path)
            .args([
                "daemon", "remote", "pair", "create", "--role", role, "--ttl", "10m",
            ]);
        json_output(command, "create remote pairing from systemd state")
    }

    pub fn assert_active_and_enabled(&self) -> Result<(), String> {
        checked(
            command("systemctl", ["is-active", self.service.as_str()]),
            "verify systemd unit active",
        )?;
        checked(
            command("systemctl", ["is-enabled", self.service.as_str()]),
            "verify systemd unit enabled",
        )?;
        Ok(())
    }

    pub fn assert_cli_status(&self) -> Result<(), String> {
        let mut command = sudo([self.binary_path.as_os_str()]);
        command.args(["daemon", "remote", "status", "--unit", &self.unit, "--json"]);
        command.arg("--env-file").arg(&self.env_path);
        let value = json_output(command, "query remote systemd status")?;
        if value["exit_code"].as_i64() == Some(0) {
            Ok(())
        } else {
            Err(format!("remote systemd status was not active: {value}"))
        }
    }

    pub fn security_exposure(&self, threshold: f64) -> Result<f64, String> {
        let mut command = command("systemd-analyze", ["--no-pager", "security"]);
        command.arg(&self.service).env("SYSTEMD_COLORS", "0");
        let output = checked(command, "analyze effective systemd security")?;
        let report = stdout(&output, "systemd security report")?;
        let exposure = report
            .lines()
            .find(|line| line.contains("Overall exposure level"))
            .and_then(|line| line.split_once(':'))
            .and_then(|(_, value)| value.split_whitespace().next())
            .ok_or_else(|| format!("systemd security report omitted exposure score: {report}"))?
            .parse::<f64>()
            .map_err(|error| format!("parse systemd security exposure: {error}; {report}"))?;
        if exposure > threshold {
            return Err(format!(
                "systemd security exposure {exposure} exceeds {threshold}: {report}"
            ));
        }
        Ok(exposure)
    }

    pub fn assert_effective_sandbox(&self) -> Result<(), String> {
        for (property, expected) in [
            ("DynamicUser", "yes"),
            ("NoNewPrivileges", "yes"),
            ("PrivateTmp", "yes"),
            ("PrivateDevices", "yes"),
            ("ProtectSystem", "strict"),
            ("ProtectHome", "yes"),
        ] {
            let actual = self.systemd_property(property)?;
            if actual != expected {
                return Err(format!(
                    "systemd property {property} was '{actual}', expected '{expected}'"
                ));
            }
        }
        for property in ["AmbientCapabilities", "CapabilityBoundingSet"] {
            let value = self.systemd_property(property)?;
            if !value.to_ascii_lowercase().contains("cap_net_bind_service") {
                return Err(format!("{property} omitted CAP_NET_BIND_SERVICE: {value}"));
            }
        }
        let pid = self.main_pid()?;
        let status_path = format!("/proc/{pid}/status");
        let output = checked(
            sudo(["cat", status_path.as_str()]),
            "read daemon process status",
        )?;
        let status = stdout(&output, "daemon process status")?;
        assert_non_root_uid(&status)?;
        assert_bind_capability(&status)
    }

    pub fn main_pid(&self) -> Result<u32, String> {
        self.systemd_property("MainPID")?
            .parse::<u32>()
            .map_err(|error| format!("parse systemd MainPID: {error}"))
            .and_then(|pid| {
                (pid > 0)
                    .then_some(pid)
                    .ok_or_else(|| "systemd MainPID is zero".to_string())
            })
    }

    pub fn environment_digest(&self) -> Result<String, String> {
        let output = checked(
            sudo([OsStr::new("sha256sum"), self.env_path.as_os_str()]),
            "hash remote systemd environment",
        )?;
        stdout(&output, "environment digest").and_then(|value| {
            value
                .split_whitespace()
                .next()
                .map(str::to_string)
                .ok_or_else(|| "sha256sum omitted environment digest".to_string())
        })
    }

    pub fn restart(&self) -> Result<(), String> {
        checked(
            sudo(["systemctl", "restart", self.service.as_str()]),
            "restart remote systemd unit",
        )?;
        self.assert_active_and_enabled()
    }

    pub fn assert_uninstalled(&self) -> Result<(), String> {
        let active = command("systemctl", ["is-active", self.service.as_str()])
            .output()
            .map_err(|error| format!("inspect uninstalled systemd unit: {error}"))?;
        if active.status.success() {
            return Err("uninstalled systemd unit remained active".to_string());
        }
        for path in [&self.unit_path, &self.env_path] {
            if path.exists() {
                return Err(format!("uninstall left {} behind", path.display()));
            }
        }
        Ok(())
    }

    pub fn with_diagnostics(&self, error: String) -> String {
        let mut command = sudo(["journalctl", "--no-pager", "-n", "200", "-u"]);
        command.arg(&self.service);
        let journal = command.output().map_or_else(
            |journal_error| format!("journal unavailable: {journal_error}"),
            |output| String::from_utf8_lossy(&output.stdout).into_owned(),
        );
        format!("{error}; systemd journal:\n{journal}")
    }

    fn systemd_property(&self, property: &str) -> Result<String, String> {
        let output = checked(
            command(
                "systemctl",
                [
                    "show",
                    "--value",
                    "--property",
                    property,
                    self.service.as_str(),
                ],
            ),
            &format!("read systemd property {property}"),
        )?;
        stdout(&output, property).map(|value| value.trim().to_string())
    }

    fn cleanup(&self) {
        let _ = sudo(["systemctl", "disable", "--now", self.service.as_str()]).output();
        let _ = sudo([
            OsStr::new("rm"),
            OsStr::new("-f"),
            self.unit_path.as_os_str(),
            self.env_path.as_os_str(),
            self.ca_path.as_os_str(),
            self.binary_path.as_os_str(),
        ])
        .output();
        let _ = sudo([
            OsStr::new("rm"),
            OsStr::new("-rf"),
            self.state_path.as_os_str(),
        ])
        .output();
        let _ = sudo(["systemctl", "daemon-reload"]).output();
        let _ = sudo(["systemctl", "reset-failed", self.service.as_str()]).output();
    }
}

impl Drop for RemoteSystemdHost {
    fn drop(&mut self) {
        self.cleanup();
    }
}

fn install_file(source: &Path, destination: &Path, mode: &str) -> Result<(), String> {
    checked(
        sudo([
            "install".as_ref(),
            "-m".as_ref(),
            mode.as_ref(),
            source.as_os_str(),
            destination.as_os_str(),
        ]),
        &format!("install {}", destination.display()),
    )?;
    Ok(())
}

fn available_low_port_pair() -> Result<(u16, u16), String> {
    for pair in [(944, 908), (943, 907), (942, 906), (941, 905)] {
        if !tcp_port_accepts(pair.0) && !tcp_port_accepts(pair.1) {
            return Ok(pair);
        }
    }
    Err("no free low-port pair available for systemd e2e".to_string())
}

fn tcp_port_accepts(port: u16) -> bool {
    TcpStream::connect_timeout(
        &SocketAddr::from(([127, 0, 0, 1], port)),
        Duration::from_millis(100),
    )
    .is_ok()
}

fn assert_non_root_uid(status: &str) -> Result<(), String> {
    let uid = process_status_value(status, "Uid:")?
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| "daemon process status omitted effective UID".to_string())?;
    if uid == "0" {
        Err("remote daemon runs as root".to_string())
    } else {
        Ok(())
    }
}

fn assert_bind_capability(status: &str) -> Result<(), String> {
    let value = process_status_value(status, "CapEff:")?;
    let capabilities = u64::from_str_radix(value.trim(), 16)
        .map_err(|error| format!("parse effective capabilities: {error}"))?;
    if capabilities & (1_u64 << 10) == 0 {
        Err("daemon process lacks effective CAP_NET_BIND_SERVICE".to_string())
    } else {
        Ok(())
    }
}

fn process_status_value<'a>(status: &'a str, key: &str) -> Result<&'a str, String> {
    status
        .lines()
        .find_map(|line| line.strip_prefix(key))
        .ok_or_else(|| format!("daemon process status omitted {key}"))
}

fn command<const N: usize>(program: &str, args: [&str; N]) -> Command {
    let mut command = Command::new(program);
    command.args(args);
    command
}

fn sudo<I, S>(args: I) -> Command
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    let mut command = Command::new("sudo");
    command.arg("-n").args(args);
    command
}

fn json_output(command: Command, action: &str) -> Result<Value, String> {
    let output = checked(command, action)?;
    let stdout = stdout(&output, action)?;
    serde_json::from_str(stdout.trim())
        .map_err(|error| format!("decode {action} JSON: {error}; stdout={stdout}"))
}

fn checked(mut command: Command, action: &str) -> Result<Output, String> {
    command.env("LC_ALL", "C");
    let output = command
        .output()
        .map_err(|error| format!("{action}: {error}"))?;
    if output.status.success() {
        Ok(output)
    } else {
        Err(format!(
            "{action} exited with {}; stdout={}; stderr={}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}

fn stdout<'a>(output: &'a Output, action: &str) -> Result<&'a str, String> {
    std::str::from_utf8(&output.stdout).map_err(|error| format!("decode {action} stdout: {error}"))
}
