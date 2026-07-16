use super::*;

fn diagnostic_child_stdio() -> Stdio {
    if std::env::var_os("HARNESS_TEST_INHERIT_CHILD_STDERR").is_some() {
        Stdio::inherit()
    } else {
        Stdio::null()
    }
}

pub(super) fn spawn_daemon_serve(home: &Path, xdg: &Path) -> ManagedChild {
    spawn_daemon_serve_with_args(home, xdg, &[])
}

pub(super) fn configure_daemon_serve_command(
    command: &mut Command,
    home: &Path,
    xdg: &Path,
    extra_args: &[&str],
) {
    let mut args = vec!["serve", "--host", "127.0.0.1", "--port", "0"];
    args.extend(extra_args);
    command
        .args(&args)
        .stdin(Stdio::null())
        .stdout(diagnostic_child_stdio())
        .stderr(diagnostic_child_stdio());
    configure_isolated_daemon_env(command, home, xdg);
}

pub(super) fn spawn_daemon_serve_with_args(
    home: &Path,
    xdg: &Path,
    extra_args: &[&str],
) -> ManagedChild {
    let mut command = Command::new(daemon_binary());
    configure_daemon_serve_command(&mut command, home, xdg, extra_args);
    ManagedChild::spawn(&mut command).expect("spawn daemon serve")
}

pub(super) fn configure_isolated_daemon_env(command: &mut Command, home: &Path, xdg: &Path) {
    configure_common_daemon_env(command, home, xdg);
    command
        .env("HARNESS_DAEMON_DATA_HOME", xdg)
        .env_remove("HARNESS_APP_GROUP_ID");
}

pub(super) fn configure_app_group_daemon_env(
    command: &mut Command,
    home: &Path,
    xdg: &Path,
    app_group_id: &str,
) {
    configure_common_daemon_env(command, home, xdg);
    command
        .env_remove("HARNESS_DAEMON_DATA_HOME")
        .env("HARNESS_APP_GROUP_ID", app_group_id);
}

fn configure_common_daemon_env(command: &mut Command, home: &Path, xdg: &Path) {
    command
        .env("HARNESS_HOST_HOME", home)
        .env("HOME", home)
        .env("XDG_DATA_HOME", xdg)
        .env_remove("HARNESS_DAEMON_OWNERSHIP")
        .env_remove("HARNESS_SANDBOXED")
        .env_remove("CLAUDE_SESSION_ID");
}

pub(super) fn spawn_bridge(home: &Path, xdg: &Path, extra_args: &[&str]) -> ManagedChild {
    spawn_bridge_inner(home, xdg, extra_args, None, None)
}

pub(super) fn spawn_bridge_with_port_lease(
    home: &Path,
    xdg: &Path,
    extra_args: &[&str],
    port_lease: TcpPortLease,
) -> ManagedChild {
    spawn_bridge_inner(home, xdg, extra_args, Some(&port_lease), None)
}

fn spawn_bridge_inner(
    home: &Path,
    xdg: &Path,
    extra_args: &[&str],
    port_lease: Option<&TcpPortLease>,
    app_group_id: Option<&str>,
) -> ManagedChild {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let mut args = vec!["start"];
        args.extend(extra_args);
        let mut command = Command::new(bridge_binary());
        command
            .args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(app_group_id) = app_group_id {
            configure_app_group_daemon_env(&mut command, home, xdg, app_group_id);
        } else {
            configure_isolated_daemon_env(&mut command, home, xdg);
        }
        let mut child = if let Some(port_lease) = port_lease {
            ManagedChild::spawn_with_port_lease(&mut command, port_lease.clone())
        } else {
            ManagedChild::spawn(&mut command)
        }
        .expect("spawn agent tui bridge");

        let startup_deadline = Instant::now() + Duration::from_secs(1);
        loop {
            match child.try_wait().expect("poll bridge start") {
                Some(_) => {
                    let output = child.wait_with_output().expect("collect bridge output");
                    assert!(
                        Instant::now() < deadline,
                        "bridge start failed: {}",
                        output_text(&output)
                    );
                    thread::sleep(DAEMON_WAIT_INTERVAL);
                    break;
                }
                None if Instant::now() >= startup_deadline => return child,
                None => thread::sleep(DAEMON_WAIT_INTERVAL),
            }
        }
    }
}

pub(super) fn spawn_bridge_with_mock_codex(
    home: &Path,
    xdg: &Path,
    base: &Path,
    capability: &str,
    extra_args: &[&str],
) -> ManagedChild {
    spawn_bridge_with_mock_codex_at_root(home, xdg, base, capability, extra_args, None)
}

pub(super) fn spawn_app_group_bridge_with_mock_codex(
    home: &Path,
    xdg: &Path,
    base: &Path,
    capability: &str,
    extra_args: &[&str],
    app_group_id: &str,
) -> ManagedChild {
    spawn_bridge_with_mock_codex_at_root(
        home,
        xdg,
        base,
        capability,
        extra_args,
        Some(app_group_id),
    )
}

fn spawn_bridge_with_mock_codex_at_root(
    home: &Path,
    xdg: &Path,
    base: &Path,
    capability: &str,
    extra_args: &[&str],
    app_group_id: Option<&str>,
) -> ManagedChild {
    let mock_codex = create_mock_codex(base);
    let codex_port = TcpPortLease::acquire().expect("reserve codex port");
    let codex_port_text = codex_port.port().to_string();
    let codex_path = mock_codex.to_str().expect("utf8 codex path");
    let mut args = vec![
        "--capability",
        capability,
        "--codex-port",
        codex_port_text.as_str(),
        "--codex-path",
        codex_path,
    ];
    args.extend(extra_args.iter().copied());
    spawn_bridge_inner(home, xdg, &args, Some(&codex_port), app_group_id)
}

pub(super) fn run_harness(home: &Path, xdg: &Path, args: &[&str]) -> Output {
    harness_command(home, xdg, args, None)
        .output()
        .expect("run harness")
}

pub(super) fn run_harness_in_app_group(
    home: &Path,
    xdg: &Path,
    args: &[&str],
    app_group_id: &str,
) -> Output {
    harness_command(home, xdg, args, Some(app_group_id))
        .output()
        .expect("run harness")
}

pub(super) fn run_harness_with_timeout(
    home: &Path,
    xdg: &Path,
    args: &[&str],
    timeout: Duration,
) -> Output {
    run_harness_with_timeout_at_root(home, xdg, args, timeout, None)
}

pub(super) fn run_harness_in_app_group_with_timeout(
    home: &Path,
    xdg: &Path,
    args: &[&str],
    timeout: Duration,
    app_group_id: &str,
) -> Output {
    run_harness_with_timeout_at_root(home, xdg, args, timeout, Some(app_group_id))
}

fn run_harness_with_timeout_at_root(
    home: &Path,
    xdg: &Path,
    args: &[&str],
    timeout: Duration,
    app_group_id: Option<&str>,
) -> Output {
    let mut child = harness_command(home, xdg, args, app_group_id)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn harness");

    let deadline = Instant::now() + timeout;
    loop {
        if child.try_wait().expect("poll harness").is_some() {
            return child.wait_with_output().expect("collect harness output");
        }
        if Instant::now() >= deadline {
            child.kill().expect("kill timed out harness process");
            let output = child.wait_with_output().expect("collect timed out output");
            panic!(
                "command did not exit before timeout: args={args:?} output={}",
                output_text(&output)
            );
        }
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

fn harness_command(home: &Path, xdg: &Path, args: &[&str], app_group_id: Option<&str>) -> Command {
    let mut command = Command::new(harness_binary());
    command.args(args);
    if let Some(app_group_id) = app_group_id {
        configure_app_group_daemon_env(&mut command, home, xdg, app_group_id);
    } else {
        configure_isolated_daemon_env(&mut command, home, xdg);
    }
    command
}

pub(crate) fn init_git_repo(path: &Path) {
    harness_testkit::init_git_repo_with_seed(path);
}

pub(super) fn wait_for_child_exit(child: &mut ManagedChild) {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        if child.try_wait().expect("poll child").is_some() {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "daemon child did not exit before timeout"
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

pub(super) fn harness_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness")
}

pub(super) fn daemon_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness-daemon")
}

pub(super) fn bridge_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness-bridge")
}

pub(super) fn output_text(output: &Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    format!("stdout={stdout:?} stderr={stderr:?}")
}
