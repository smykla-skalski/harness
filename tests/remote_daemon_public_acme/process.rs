use std::ffi::OsString;
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;
use tempfile::TempDir;

use super::config::{LETS_ENCRYPT_STAGING_DIRECTORY, PublicAcmeChallenge, PublicAcmeConfig};

pub struct PublicAcmeEnvironment {
    _temp: TempDir,
    home: PathBuf,
    xdg: PathBuf,
    data_home: PathBuf,
    logs: PathBuf,
    binary: PathBuf,
}

impl PublicAcmeEnvironment {
    pub fn new() -> Result<Self, String> {
        let temp = tempfile::Builder::new()
            .prefix("harness-public-acme-e2e-")
            .tempdir()
            .map_err(|error| format!("create public ACME tempdir: {error}"))?;
        let home = temp.path().join("home");
        let xdg = temp.path().join("xdg");
        let data_home = temp.path().join("daemon-data");
        let logs = temp.path().join("logs");
        for path in [&home, &xdg, &data_home, &logs] {
            fs::create_dir_all(path)
                .map_err(|error| format!("create {}: {error}", path.display()))?;
        }
        let binary = prepare_capable_binary(temp.path())?;
        Ok(Self {
            _temp: temp,
            home,
            xdg,
            data_home,
            logs,
            binary,
        })
    }

    pub fn spawn<'a>(
        &'a self,
        config: &'a PublicAcmeConfig,
        domain: &str,
        challenge: PublicAcmeChallenge,
    ) -> Result<PublicAcmeProcess<'a>, String> {
        let log_stem = domain.replace('.', "-");
        let stdout_path = self.logs.join(format!("{log_stem}.stdout.log"));
        let stderr_path = self.logs.join(format!("{log_stem}.stderr.log"));
        let stdout = File::create(&stdout_path)
            .map_err(|error| format!("create public ACME stdout log: {error}"))?;
        let stderr = File::create(&stderr_path)
            .map_err(|error| format!("create public ACME stderr log: {error}"))?;
        let mut command = self.command(config);
        command
            .args(remote_daemon_args(domain, &config.email, challenge))
            .stdin(Stdio::null())
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr));
        let child = command
            .spawn()
            .map_err(|error| format!("spawn public ACME daemon: {error}"))?;
        Ok(PublicAcmeProcess {
            child,
            environment: self,
            config,
            stdout_path,
            stderr_path,
        })
    }

    fn command(&self, config: &PublicAcmeConfig) -> Command {
        let mut command = Command::new(&self.binary);
        apply_environment(&mut command, config, &self.home, &self.xdg, &self.data_home);
        command
    }

    fn run_json(&self, config: &PublicAcmeConfig, args: &[&str]) -> Result<Value, String> {
        let output = self
            .command(config)
            .args(args)
            .output()
            .map_err(|error| format!("run public ACME harness command: {error}"))?;
        if !output.status.success() {
            return Err(format!(
                "public ACME harness command failed with {}: stdout={} stderr={}",
                output.status,
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        serde_json::from_slice(&output.stdout).map_err(|error| {
            format!(
                "decode public ACME harness JSON: {error}; stdout={}",
                String::from_utf8_lossy(&output.stdout)
            )
        })
    }
}

pub struct PublicAcmeProcess<'a> {
    child: Child,
    environment: &'a PublicAcmeEnvironment,
    config: &'a PublicAcmeConfig,
    stdout_path: PathBuf,
    stderr_path: PathBuf,
}

impl PublicAcmeProcess<'_> {
    pub fn create_pairing(&self, role: &str) -> Result<Value, String> {
        self.environment.run_json(
            self.config,
            &["remote", "pair", "create", "--role", role, "--ttl", "10m"],
        )
    }

    pub fn ensure_running(&mut self) -> Result<(), String> {
        match self.child.try_wait() {
            Ok(None) => Ok(()),
            Ok(Some(status)) => Err(format!(
                "public ACME daemon exited with {status}; {}",
                self.diagnostics()
            )),
            Err(error) => Err(format!("poll public ACME daemon: {error}")),
        }
    }

    pub async fn wait_for_exit(&mut self) -> Result<(), String> {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            match self.child.try_wait() {
                Ok(Some(status)) if status.success() => return Ok(()),
                Ok(Some(status)) => {
                    return Err(format!(
                        "public ACME daemon exited with {status}; {}",
                        self.diagnostics()
                    ));
                }
                Ok(None) if Instant::now() < deadline => {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
                Ok(None) => {
                    return Err(format!(
                        "public ACME daemon did not stop; {}",
                        self.diagnostics()
                    ));
                }
                Err(error) => return Err(format!("wait for public ACME daemon: {error}")),
            }
        }
    }

    pub fn diagnostics(&self) -> String {
        let stdout = fs::read_to_string(&self.stdout_path).unwrap_or_default();
        let stderr = fs::read_to_string(&self.stderr_path).unwrap_or_default();
        format!("stdout:\n{stdout}\nstderr:\n{stderr}")
    }
}

impl Drop for PublicAcmeProcess<'_> {
    fn drop(&mut self) {
        terminate_child_now(&mut self.child);
    }
}

fn terminate_child_now(child: &mut Child) {
    let poll = child.try_wait();
    if child_may_still_be_running(&poll) {
        let _ = child.kill();
        let _ = child.wait();
    }
}

fn child_may_still_be_running(poll: &std::io::Result<Option<std::process::ExitStatus>>) -> bool {
    !matches!(poll, Ok(Some(_)))
}

pub fn remote_daemon_args(
    domain: &str,
    email: &str,
    challenge: PublicAcmeChallenge,
) -> Vec<String> {
    let mut args = [
        "remote",
        "serve",
        "--domain",
        domain,
        "--host",
        "0.0.0.0",
        "--https-port",
        "443",
        "--http-port",
        "80",
        "--acme-email",
        email,
        "--acme-challenge",
        challenge.cli_name(),
    ]
    .map(str::to_string)
    .to_vec();
    if challenge == PublicAcmeChallenge::Dns {
        args.extend(["--acme-dns-provider".to_string(), "aftermarket".to_string()]);
    }
    args
}

fn apply_environment(
    command: &mut Command,
    config: &PublicAcmeConfig,
    home: &Path,
    xdg: &Path,
    data_home: &Path,
) {
    command
        .env("HOME", home)
        .env("HARNESS_HOST_HOME", home)
        .env("XDG_DATA_HOME", xdg)
        .env("HARNESS_DAEMON_DATA_HOME", data_home)
        .env("HARNESS_DAEMON_OWNERSHIP", "external")
        .env(
            "HARNESS_REMOTE_ACME_DIRECTORY_URL",
            LETS_ENCRYPT_STAGING_DIRECTORY,
        )
        .env_remove("HARNESS_REMOTE_ACME_CA_ROOT")
        .env("HARNESS_REMOTE_ACME_AFTERMARKET_API_BASE", &config.api_base)
        .env("AFTERMARKET_ZONE_NAME", &config.zone_name)
        .env("AFTERMARKET_API_KEY", &config.api_key)
        .env("AFTERMARKET_API_SECRET", &config.api_secret)
        .env("RUST_LOG", "harness=debug");
}

#[cfg(target_os = "linux")]
fn prepare_capable_binary(root: &Path) -> Result<PathBuf, String> {
    use std::os::unix::fs::PermissionsExt as _;

    let source = assert_cmd::cargo::cargo_bin("harness-daemon");
    let binary = root.join("harness-daemon-public-acme");
    fs::copy(&source, &binary).map_err(|error| {
        format!(
            "copy public ACME harness binary from {}: {error}",
            source.display()
        )
    })?;
    fs::set_permissions(&binary, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("protect public ACME harness binary: {error}"))?;
    let setcap = system_command("/usr/sbin/setcap", "setcap");
    let status = Command::new("sudo")
        .arg("-n")
        .arg(setcap)
        .arg("cap_net_bind_service=+ep")
        .arg(&binary)
        .status()
        .map_err(|error| format!("grant public ACME bind capability: {error}"))?;
    if !status.success() {
        return Err(format!(
            "grant CAP_NET_BIND_SERVICE to {} failed with {status}",
            binary.display()
        ));
    }
    let getcap = system_command("/usr/sbin/getcap", "getcap");
    let output = Command::new(getcap)
        .arg(&binary)
        .output()
        .map_err(|error| format!("verify public ACME bind capability: {error}"))?;
    let capabilities = String::from_utf8_lossy(&output.stdout);
    if !output.status.success() || !capabilities.contains("cap_net_bind_service=ep") {
        return Err(capability_verification_error(
            &binary,
            &output.status.to_string(),
            &output.stdout,
            &output.stderr,
        ));
    }
    Ok(binary)
}

fn capability_verification_error(
    binary: &Path,
    status: &str,
    stdout: &[u8],
    stderr: &[u8],
) -> String {
    format!(
        "public ACME binary {} lacks CAP_NET_BIND_SERVICE or getcap failed with {status}; stdout={}; stderr={}",
        binary.display(),
        String::from_utf8_lossy(stdout).trim(),
        String::from_utf8_lossy(stderr).trim(),
    )
}

#[cfg(not(target_os = "linux"))]
fn prepare_capable_binary(_root: &Path) -> Result<PathBuf, String> {
    Err("public ACME proof requires Linux CAP_NET_BIND_SERVICE support".to_string())
}

#[cfg(target_os = "linux")]
fn system_command<'a>(absolute: &'a str, fallback: &'a str) -> &'a str {
    if Path::new(absolute).is_file() {
        absolute
    } else {
        fallback
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::io;

    use super::*;

    #[test]
    fn public_acme_drop_attempts_cleanup_after_poll_error() {
        let poll = Err(io::Error::other("poll failed"));

        assert!(child_may_still_be_running(&poll));
    }

    #[test]
    fn public_acme_drop_cleanup_kills_without_grace_wait() {
        let mut child = Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .expect("spawn long-running child");
        let started = Instant::now();

        terminate_child_now(&mut child);

        assert!(started.elapsed() < Duration::from_secs(2));
        assert!(matches!(child.try_wait(), Ok(Some(_))));
    }

    #[test]
    fn getcap_failure_reports_status_and_stderr() {
        let error = capability_verification_error(
            Path::new("/tmp/harness-daemon-public-acme"),
            "exit status: 1",
            b"",
            b"permission denied",
        );

        assert!(error.contains("exit status: 1"));
        assert!(error.contains("stderr=permission denied"));
    }

    #[test]
    fn public_acme_daemon_args_bind_standard_public_ports() {
        let args = remote_daemon_args(
            "tls.remote.example.com",
            "ops@example.com",
            PublicAcmeChallenge::TlsAlpn,
        );

        assert_eq!(
            args,
            [
                "remote",
                "serve",
                "--domain",
                "tls.remote.example.com",
                "--host",
                "0.0.0.0",
                "--https-port",
                "443",
                "--http-port",
                "80",
                "--acme-email",
                "ops@example.com",
                "--acme-challenge",
                "tls-alpn",
            ]
        );
    }

    #[test]
    fn public_acme_dns_args_select_aftermarket_only_for_dns_challenge() {
        for challenge in [PublicAcmeChallenge::TlsAlpn, PublicAcmeChallenge::Http] {
            let args = remote_daemon_args("remote.example.com", "ops@example.com", challenge);
            assert!(!args.iter().any(|arg| arg == "--acme-dns-provider"));
        }

        let dns = remote_daemon_args(
            "dns.remote.example.com",
            "ops@example.com",
            PublicAcmeChallenge::Dns,
        );
        assert_eq!(
            &dns[dns.len() - 2..],
            ["--acme-dns-provider", "aftermarket"]
        );
    }

    #[test]
    fn public_acme_environment_pins_staging_and_isolated_state() {
        let temp = tempfile::tempdir().expect("environment tempdir");
        let config = test_config();
        let mut command = Command::new("harness-daemon");
        apply_environment(
            &mut command,
            &config,
            &temp.path().join("home"),
            &temp.path().join("xdg"),
            &temp.path().join("data"),
        );
        let environment = command
            .get_envs()
            .filter_map(|(name, value)| {
                value.map(|value| (name.to_os_string(), value.to_os_string()))
            })
            .collect::<HashMap<OsString, OsString>>();

        assert_eq!(
            environment.get(&OsString::from("HARNESS_REMOTE_ACME_DIRECTORY_URL")),
            Some(&OsString::from(LETS_ENCRYPT_STAGING_DIRECTORY))
        );
        assert_eq!(
            environment.get(&OsString::from("HARNESS_DAEMON_DATA_HOME")),
            Some(&temp.path().join("data").into_os_string())
        );
        assert_eq!(
            environment.get(&OsString::from("AFTERMARKET_API_KEY")),
            Some(&OsString::from("public-key"))
        );
        assert_eq!(
            environment.get(&OsString::from("AFTERMARKET_API_SECRET")),
            Some(&OsString::from("secret-key"))
        );
    }

    fn test_config() -> PublicAcmeConfig {
        PublicAcmeConfig {
            base_domain: "remote.example.com".to_string(),
            ipv4: "8.8.8.8".parse().expect("IPv4"),
            email: "ops@example.com".to_string(),
            zone_name: "example.com".to_string(),
            api_base: "https://aftermarket.test".to_string(),
            api_key: "public-key".to_string(),
            api_secret: "secret-key".to_string(),
        }
    }
}
