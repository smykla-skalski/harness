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

pub(super) fn spawn_daemon_serve_with_args(
    home: &Path,
    xdg: &Path,
    extra_args: &[&str],
) -> ManagedChild {
    let mut args = vec!["daemon", "serve", "--host", "127.0.0.1", "--port", "0"];
    args.extend(extra_args);
    ManagedChild::spawn(
        Command::new(harness_binary())
            .args(&args)
            .env("HARNESS_HOST_HOME", home)
            .env("HOME", home)
            .env("HARNESS_HOST_HOME", home)
            .env("XDG_DATA_HOME", xdg)
            .stdin(Stdio::null())
            .stdout(diagnostic_child_stdio())
            .stderr(diagnostic_child_stdio()),
    )
    .expect("spawn daemon serve")
}

pub(super) fn spawn_bridge(home: &Path, xdg: &Path, extra_args: &[&str]) -> ManagedChild {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let mut args = vec!["bridge", "start"];
        args.extend(extra_args);
        let mut child = ManagedChild::spawn(
            Command::new(harness_binary())
                .args(&args)
                .env("HARNESS_HOST_HOME", home)
                .env("HOME", home)
                .env("HARNESS_HOST_HOME", home)
                .env("XDG_DATA_HOME", xdg)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped()),
        )
        .expect("spawn agent tui bridge");

        let startup_deadline = Instant::now() + Duration::from_secs(1);
        loop {
            match child.try_wait().expect("poll bridge start") {
                Some(_) => {
                    let output = child.wait_with_output().expect("collect bridge output");
                    if Instant::now() >= deadline {
                        panic!("bridge start failed: {}", output_text(&output));
                    }
                    thread::sleep(DAEMON_WAIT_INTERVAL);
                    break;
                }
                None if Instant::now() >= startup_deadline => return child,
                None => thread::sleep(DAEMON_WAIT_INTERVAL),
            }
        }
    }
}

pub(super) fn run_harness(home: &Path, xdg: &Path, args: &[&str]) -> Output {
    Command::new(harness_binary())
        .args(args)
        .env("HARNESS_HOST_HOME", home)
        .env("HOME", home)
        .env("HARNESS_HOST_HOME", home)
        .env("XDG_DATA_HOME", xdg)
        .output()
        .expect("run harness")
}

pub(super) fn run_harness_with_timeout(
    home: &Path,
    xdg: &Path,
    args: &[&str],
    timeout: Duration,
) -> Output {
    let mut child = Command::new(harness_binary())
        .args(args)
        .env("HARNESS_HOST_HOME", home)
        .env("HOME", home)
        .env("HARNESS_HOST_HOME", home)
        .env("XDG_DATA_HOME", xdg)
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

pub(super) fn init_git_repo(path: &Path) {
    std::fs::create_dir_all(path).expect("create project");
    let status = Command::new("git")
        .arg("init")
        .arg("-q")
        .arg(path)
        .status()
        .expect("git init");
    assert!(status.success(), "git init failed");
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

pub(super) fn unused_local_port() -> u16 {
    TcpListener::bind(("127.0.0.1", 0))
        .expect("bind local port")
        .local_addr()
        .expect("read local addr")
        .port()
}

pub(super) fn harness_binary() -> PathBuf {
    assert_cmd::cargo::cargo_bin("harness")
}

pub(super) fn output_text(output: &Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    format!("stdout={stdout:?} stderr={stderr:?}")
}
