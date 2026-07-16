use std::fs::{self, DirBuilder, File, OpenOptions};
use std::net::TcpListener;
use std::os::unix::fs::{DirBuilderExt as _, MetadataExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use fs2::FileExt as _;
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
    https_port: PortLease,
    http_port: PortLease,
}

pub struct AftermarketDnsEnvironment<'a> {
    pub zone_name: &'a str,
    pub api_key: &'a str,
    pub api_secret: &'a str,
    pub visibility_timeout_seconds: u64,
    pub visibility_poll_seconds: u64,
    pub visibility_stable_polls: usize,
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
            https_port: PortLease::acquire()?,
            http_port: PortLease::acquire()?,
        }
        .with_log_paths())
    }

    fn with_log_paths(mut self) -> Self {
        self.daemon_stdout = self.temp.path().join(&self.daemon_stdout);
        self.daemon_stderr = self.temp.path().join(&self.daemon_stderr);
        self
    }

    pub fn https_port(&self) -> u16 {
        self.https_port.port
    }

    pub fn http_port(&self) -> u16 {
        self.http_port.port
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

    fn release_port_reservations(&self) -> Result<(), String> {
        self.https_port.release_socket()?;
        self.http_port.release_socket()
    }
}

struct PortLease {
    port: u16,
    listener: Mutex<Option<TcpListener>>,
    _lock_file: File,
}

impl PortLease {
    fn acquire() -> Result<Self, String> {
        for _ in 0..32 {
            let listener = TcpListener::bind(("127.0.0.1", 0))
                .map_err(|error| format!("reserve local port: {error}"))?;
            let port = listener
                .local_addr()
                .map_err(|error| format!("read reserved local port: {error}"))?
                .port();
            let lock_path = port_lock_root()?.join(format!("tcp-{port}.lock"));
            let lock_file = OpenOptions::new()
                .create(true)
                .read(true)
                .write(true)
                .truncate(false)
                .open(&lock_path)
                .map_err(|error| format!("open port lease {}: {error}", lock_path.display()))?;
            match lock_file.try_lock_exclusive() {
                Ok(()) => {
                    return Ok(Self {
                        port,
                        listener: Mutex::new(Some(listener)),
                        _lock_file: lock_file,
                    });
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(error) => {
                    return Err(format!("lock port lease {}: {error}", lock_path.display()));
                }
            }
        }
        Err("could not reserve a unique local port after 32 attempts".to_string())
    }

    fn release_socket(&self) -> Result<(), String> {
        self.listener
            .lock()
            .map_err(|_| "port reservation lock poisoned".to_string())?
            .take();
        Ok(())
    }
}

fn port_lock_root() -> Result<PathBuf, String> {
    let uid = uzers::get_current_uid();
    let root = PathBuf::from("/tmp").join(format!("harness-test-port-leases-{uid}"));
    match DirBuilder::new().mode(0o700).create(&root) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => {
            return Err(format!(
                "create port lease root {}: {error}",
                root.display()
            ));
        }
    }
    let metadata = fs::symlink_metadata(&root)
        .map_err(|error| format!("inspect port lease root {}: {error}", root.display()))?;
    if !metadata.file_type().is_dir() || metadata.uid() != uid {
        return Err(format!(
            "port lease root must be an owned directory: {}",
            root.display()
        ));
    }
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("secure port lease root {}: {error}", root.display()))?;
    Ok(root)
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
        let dns_provider = (challenge == AcmeChallenge::Dns).then_some("exec");
        let mut command =
            remote_daemon_command(environment, super::DOMAIN, challenge, dns_provider);
        environment.apply(&mut command, directory_url);
        Self::spawn_command(environment, directory_url, command)
    }

    pub fn spawn_aftermarket(
        environment: &RemoteDaemonEnvironment,
        domain: &str,
        directory_url: &str,
        aftermarket: &AftermarketDnsEnvironment<'_>,
    ) -> Result<Self, String> {
        let mut command =
            remote_daemon_command(environment, domain, AcmeChallenge::Dns, Some("aftermarket"));
        environment.apply(&mut command, directory_url);
        command
            .env("AFTERMARKET_ZONE_NAME", aftermarket.zone_name)
            .env("AFTERMARKET_API_KEY", aftermarket.api_key)
            .env("AFTERMARKET_API_SECRET", aftermarket.api_secret)
            .env(
                "HARNESS_REMOTE_ACME_DNS_VISIBILITY_TIMEOUT_SECONDS",
                aftermarket.visibility_timeout_seconds.to_string(),
            )
            .env(
                "HARNESS_REMOTE_ACME_DNS_VISIBILITY_POLL_SECONDS",
                aftermarket.visibility_poll_seconds.to_string(),
            )
            .env(
                "HARNESS_REMOTE_ACME_DNS_VISIBILITY_STABLE_POLLS",
                aftermarket.visibility_stable_polls.to_string(),
            );
        Self::spawn_command(environment, directory_url, command)
    }

    fn spawn_command(
        environment: &RemoteDaemonEnvironment,
        directory_url: &str,
        mut command: Command,
    ) -> Result<Self, String> {
        environment.release_port_reservations()?;
        let stdout = File::create(&environment.daemon_stdout)
            .map_err(|error| format!("create daemon stdout log: {error}"))?;
        let stderr = File::create(&environment.daemon_stderr)
            .map_err(|error| format!("create daemon stderr log: {error}"))?;
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
        self.run_json(&["remote", "pair", "create", "--role", role, "--ttl", "10m"])
    }

    pub fn revoke_client(&self, client_id: &str) -> Result<Value, String> {
        self.run_json(&["remote", "clients", "revoke", "--client-id", client_id])
    }

    pub fn rotate_client(&self, client_id: &str) -> Result<Value, String> {
        self.run_json(&["remote", "clients", "rotate", "--client-id", client_id])
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

    pub async fn wait_for_failure(&mut self, wait_timeout: Duration) -> Result<String, String> {
        let deadline = Instant::now() + wait_timeout;
        loop {
            match self.child.try_wait() {
                Ok(Some(status)) if status.success() => {
                    return Err(format!(
                        "remote daemon unexpectedly succeeded; {}",
                        self.diagnostics()
                    ));
                }
                Ok(Some(_)) => return Ok(self.diagnostics()),
                Ok(None) if Instant::now() < deadline => {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
                Ok(None) => {
                    return Err(format!(
                        "remote daemon did not fail within {wait_timeout:?}; {}",
                        self.diagnostics()
                    ));
                }
                Err(error) => return Err(format!("wait for remote daemon failure: {error}")),
            }
        }
    }

    pub fn diagnostics(&self) -> String {
        let stdout = fs::read_to_string(&self.stdout_path).unwrap_or_default();
        let stderr = fs::read_to_string(&self.stderr_path).unwrap_or_default();
        format!("stdout:\n{stdout}\nstderr:\n{stderr}")
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
    assert_cmd::cargo::cargo_bin("harness-daemon")
}

fn remote_daemon_command(
    environment: &RemoteDaemonEnvironment,
    domain: &str,
    challenge: AcmeChallenge,
    dns_provider: Option<&str>,
) -> Command {
    let mut command = Command::new(harness_binary());
    command.args([
        "remote",
        "serve",
        "--domain",
        domain,
        "--host",
        "127.0.0.1",
        "--https-port",
        &environment.https_port().to_string(),
        "--http-port",
        &environment.http_port().to_string(),
        "--acme-email",
        "remote-e2e@example.com",
        "--acme-challenge",
        challenge.cli_name(),
    ]);
    if let Some(provider) = dns_provider {
        command.args(["--acme-dns-provider", provider]);
    }
    command
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
