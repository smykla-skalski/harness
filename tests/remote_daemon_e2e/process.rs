use std::fs::{self, File};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;
use tempfile::TempDir;

use super::acme::AcmeChallenge;

pub struct RemoteDaemonEnvironment {
    temp: TempDir,
    home: PathBuf,
    xdg: PathBuf,
    data_home: PathBuf,
    dns_hook: PathBuf,
    dns_log: PathBuf,
    acme_ca_root: PathBuf,
    daemon_stdout: PathBuf,
    daemon_stderr: PathBuf,
    https_port: u16,
    http_port: u16,
}

impl RemoteDaemonEnvironment {
    pub fn new(challenge: AcmeChallenge) -> Result<Self, String> {
        let temp = tempfile::Builder::new()
            .prefix(&format!("harness-remote-e2e-{}-", challenge.cli_name()))
            .tempdir()
            .map_err(|error| format!("create remote e2e tempdir: {error}"))?;
        let home = temp.path().join("home");
        let xdg = temp.path().join("xdg");
        let data_home = temp.path().join("daemon-data");
        for path in [&home, &xdg, &data_home] {
            fs::create_dir_all(path)
                .map_err(|error| format!("create {}: {error}", path.display()))?;
        }
        let dns_hook = temp.path().join("dns-hook.sh");
        let dns_log = temp.path().join("dns-hook.log");
        let acme_ca_root = temp.path().join("fake-acme-ca.pem");
        write_dns_hook(&dns_hook)?;
        Ok(Self {
            temp,
            home,
            xdg,
            data_home,
            dns_hook,
            dns_log,
            acme_ca_root,
            daemon_stdout: PathBuf::from("daemon.stdout.log"),
            daemon_stderr: PathBuf::from("daemon.stderr.log"),
            https_port: unused_port()?,
            http_port: unused_port()?,
        }
        .with_log_paths())
    }

    fn with_log_paths(mut self) -> Self {
        self.daemon_stdout = self.temp.path().join(&self.daemon_stdout);
        self.daemon_stderr = self.temp.path().join(&self.daemon_stderr);
        self
    }

    pub const fn https_port(&self) -> u16 {
        self.https_port
    }

    pub const fn http_port(&self) -> u16 {
        self.http_port
    }

    pub fn dns_log(&self) -> &Path {
        &self.dns_log
    }

    pub fn acme_ca_root(&self) -> &Path {
        &self.acme_ca_root
    }

    fn apply(&self, command: &mut Command, directory_url: &str) {
        command
            .env("HOME", &self.home)
            .env("HARNESS_HOST_HOME", &self.home)
            .env("XDG_DATA_HOME", &self.xdg)
            .env("HARNESS_DAEMON_DATA_HOME", &self.data_home)
            .env("HARNESS_DAEMON_OWNERSHIP", "external")
            .env("HARNESS_REMOTE_ACME_DIRECTORY_URL", directory_url)
            .env("HARNESS_REMOTE_ACME_CA_ROOT", &self.acme_ca_root)
            .env("HARNESS_REMOTE_ACME_DNS_PROPAGATION_SECONDS", "0")
            .env("HARNESS_REMOTE_ACME_DNS_EXEC", &self.dns_hook)
            .env("HARNESS_REMOTE_ACME_DNS_LOG", &self.dns_log)
            .env("RUST_LOG", "harness=debug");
    }
}

pub struct RemoteDaemonProcess {
    child: Child,
    directory_url: String,
    home: PathBuf,
    xdg: PathBuf,
    data_home: PathBuf,
    dns_hook: PathBuf,
    dns_log: PathBuf,
    acme_ca_root: PathBuf,
    stdout_path: PathBuf,
    stderr_path: PathBuf,
}

impl RemoteDaemonProcess {
    pub fn spawn(
        environment: &RemoteDaemonEnvironment,
        challenge: AcmeChallenge,
        directory_url: &str,
    ) -> Result<Self, String> {
        let stdout = File::create(&environment.daemon_stdout)
            .map_err(|error| format!("create daemon stdout log: {error}"))?;
        let stderr = File::create(&environment.daemon_stderr)
            .map_err(|error| format!("create daemon stderr log: {error}"))?;
        let mut command = Command::new(harness_binary());
        command.args([
            "daemon",
            "remote",
            "serve",
            "--domain",
            super::DOMAIN,
            "--host",
            "127.0.0.1",
            "--https-port",
            &environment.https_port.to_string(),
            "--http-port",
            &environment.http_port.to_string(),
            "--acme-email",
            "remote-e2e@example.com",
            "--acme-challenge",
            challenge.cli_name(),
        ]);
        if challenge == AcmeChallenge::Dns {
            command.args(["--acme-dns-provider", "exec"]);
        }
        environment.apply(&mut command, directory_url);
        let child = command
            .stdin(Stdio::null())
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr))
            .spawn()
            .map_err(|error| format!("spawn remote daemon: {error}"))?;
        Ok(Self {
            child,
            directory_url: directory_url.to_string(),
            home: environment.home.clone(),
            xdg: environment.xdg.clone(),
            data_home: environment.data_home.clone(),
            dns_hook: environment.dns_hook.clone(),
            dns_log: environment.dns_log.clone(),
            acme_ca_root: environment.acme_ca_root.clone(),
            stdout_path: environment.daemon_stdout.clone(),
            stderr_path: environment.daemon_stderr.clone(),
        })
    }

    pub fn ensure_running(&mut self) -> Result<(), String> {
        match self.child.try_wait() {
            Ok(None) => Ok(()),
            Ok(Some(status)) => Err(format!(
                "remote daemon exited with {status}; {}",
                self.diagnostics()
            )),
            Err(error) => Err(format!("poll remote daemon: {error}")),
        }
    }

    pub fn create_pairing(&self, role: &str) -> Result<Value, String> {
        self.run_json(&[
            "daemon", "remote", "pair", "create", "--role", role, "--ttl", "10m",
        ])
    }

    pub fn revoke_client(&self, client_id: &str) -> Result<Value, String> {
        self.run_json(&[
            "daemon",
            "remote",
            "clients",
            "revoke",
            "--client-id",
            client_id,
        ])
    }

    fn run_json(&self, args: &[&str]) -> Result<Value, String> {
        let mut command = Command::new(harness_binary());
        command.args(args);
        self.apply_environment(&mut command);
        let output = command
            .output()
            .map_err(|error| format!("run harness {args:?}: {error}"))?;
        if !output.status.success() {
            return Err(format!(
                "harness {args:?} failed with {}: stdout={} stderr={}",
                output.status,
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        serde_json::from_slice(&output.stdout).map_err(|error| {
            format!(
                "parse harness {args:?} JSON: {error}; stdout={}",
                String::from_utf8_lossy(&output.stdout)
            )
        })
    }

    fn apply_environment(&self, command: &mut Command) {
        command
            .env("HOME", &self.home)
            .env("HARNESS_HOST_HOME", &self.home)
            .env("XDG_DATA_HOME", &self.xdg)
            .env("HARNESS_DAEMON_DATA_HOME", &self.data_home)
            .env("HARNESS_DAEMON_OWNERSHIP", "external")
            .env("HARNESS_REMOTE_ACME_DIRECTORY_URL", &self.directory_url)
            .env("HARNESS_REMOTE_ACME_CA_ROOT", &self.acme_ca_root)
            .env("HARNESS_REMOTE_ACME_DNS_PROPAGATION_SECONDS", "0")
            .env("HARNESS_REMOTE_ACME_DNS_EXEC", &self.dns_hook)
            .env("HARNESS_REMOTE_ACME_DNS_LOG", &self.dns_log);
    }

    pub async fn wait_for_exit(&mut self) -> Result<(), String> {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            match self.child.try_wait() {
                Ok(Some(status)) if status.success() => return Ok(()),
                Ok(Some(status)) => {
                    return Err(format!(
                        "remote daemon stopped with {status}; {}",
                        self.diagnostics()
                    ));
                }
                Ok(None) if Instant::now() < deadline => {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
                Ok(None) => {
                    return Err(format!(
                        "remote daemon did not stop; {}",
                        self.diagnostics()
                    ));
                }
                Err(error) => return Err(format!("wait for remote daemon: {error}")),
            }
        }
    }

    pub fn diagnostics(&self) -> String {
        format!(
            "stdout={:?} stderr={:?}",
            fs::read_to_string(&self.stdout_path).unwrap_or_default(),
            fs::read_to_string(&self.stderr_path).unwrap_or_default()
        )
    }
}

impl Drop for RemoteDaemonProcess {
    fn drop(&mut self) {
        if matches!(self.child.try_wait(), Ok(None)) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

fn harness_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness")
}

fn unused_port() -> Result<u16, String> {
    TcpListener::bind(("127.0.0.1", 0))
        .and_then(|listener| listener.local_addr())
        .map(|address| address.port())
        .map_err(|error| format!("reserve unused local port: {error}"))
}

fn write_dns_hook(path: &Path) -> Result<(), String> {
    fs::write(
        path,
        "#!/bin/sh\nprintf '%s|%s|%s\\n' \"$1\" \"$2\" \"$3\" >> \"$HARNESS_REMOTE_ACME_DNS_LOG\"\n",
    )
    .map_err(|error| format!("write DNS hook: {error}"))?;
    let mut permissions = fs::metadata(path)
        .map_err(|error| format!("read DNS hook permissions: {error}"))?
        .permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(path, permissions)
        .map_err(|error| format!("set DNS hook permissions: {error}"))
}
