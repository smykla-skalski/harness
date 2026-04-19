use super::*;
use std::io::{ErrorKind, Read, Write};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use portable_pty::{CommandBuilder, PtySize, native_pty_system};

#[test]
fn local_agent_tui_attach_replays_existing_screen_and_keeps_streaming() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo(&project);

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    let _daemon_ready = wait_for_daemon_ready(&home, &xdg);
    let project_arg = project.to_str().expect("utf8 project");
    let session = start_session_via_http(
        &home,
        &xdg,
        project_arg,
        "attach-local-daemon",
        "attach replay coverage",
        "verify attach replays the current terminal state and keeps streaming",
    );

    let start_output = run_harness_with_timeout(
        &home,
        &xdg,
        &[
            "session",
            "tui",
            "start",
            session.session_id.as_str(),
            "--runtime",
            "codex",
            "--role",
            "worker",
            "--name",
            "Attach Replay",
            "--arg=sh",
            "--arg=-c",
            "--arg=printf 'already-there\\n'; sleep 2; printf 'attach-live\\n'; cat",
        ],
        COMMAND_WAIT_TIMEOUT,
    );
    assert!(
        start_output.status.success(),
        "tui start failed: {}",
        output_text(&start_output)
    );
    let started: AgentTuiSnapshot =
        serde_json::from_slice(&start_output.stdout).expect("parse tui start");
    assert_eq!(started.status, AgentTuiStatus::Running);

    let live_snapshot = wait_for_tui_screen_text(&home, &xdg, &started.tui_id, "already-there");
    assert!(
        live_snapshot.screen.text.contains("already-there"),
        "show should confirm pre-attach output: {:?}",
        live_snapshot.screen.text
    );

    let mut attached = AttachedTuiSession::spawn(&home, &xdg, &started.tui_id);
    attached.wait_for_output("attach-live");
    assert!(
        attached.output_text().contains("already-there"),
        "attach output should replay existing screen state before live bytes; output={:?}",
        attached.output_text()
    );

    attached.write_line("from attach");
    attached.wait_for_output("from attach");

    let stop_output = run_harness(
        &home,
        &xdg,
        &["session", "tui", "stop", started.tui_id.as_str()],
    );
    assert!(
        stop_output.status.success(),
        "tui stop failed: {}",
        output_text(&stop_output)
    );
    attached.wait_for_exit();

    daemon.kill().expect("kill daemon");
    wait_for_child_exit(&mut daemon);
}

#[test]
fn sandboxed_agent_tui_attach_replays_existing_screen_and_keeps_streaming() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo(&project);

    let mut daemon = spawn_daemon_serve_with_args(&home, &xdg, &["--sandboxed"]);
    let _initial_status = wait_for_daemon_ready(&home, &xdg);
    let mut bridge = spawn_bridge_with_mock_codex(&home, &xdg, tmp.path(), "agent-tui", &[]);
    let _bridge_status = wait_for_bridge_capabilities(&home, &xdg, &["agent-tui"]);
    let _daemon_ready = wait_for_daemon_ready(&home, &xdg);

    let project_arg = project.to_str().expect("utf8 project");
    let session = start_session_via_http(
        &home,
        &xdg,
        project_arg,
        "attach-sandboxed-daemon",
        "attach replay coverage",
        "verify sandboxed attach replays the current terminal state and keeps streaming",
    );

    let start_output = run_harness_with_timeout(
        &home,
        &xdg,
        &[
            "session",
            "tui",
            "start",
            session.session_id.as_str(),
            "--runtime",
            "codex",
            "--role",
            "worker",
            "--name",
            "Attach Replay",
            "--arg=sh",
            "--arg=-c",
            "--arg=printf 'already-there\\n'; sleep 2; printf 'attach-live\\n'; cat",
        ],
        COMMAND_WAIT_TIMEOUT,
    );
    assert!(
        start_output.status.success(),
        "tui start failed: {}",
        output_text(&start_output)
    );
    let started: AgentTuiSnapshot =
        serde_json::from_slice(&start_output.stdout).expect("parse tui start");
    assert_eq!(started.status, AgentTuiStatus::Running);

    let live_snapshot = wait_for_tui_screen_text(&home, &xdg, &started.tui_id, "already-there");
    assert!(
        live_snapshot.screen.text.contains("already-there"),
        "show should confirm pre-attach output: {:?}",
        live_snapshot.screen.text
    );

    let mut attached = AttachedTuiSession::spawn(&home, &xdg, &started.tui_id);
    attached.wait_for_output("attach-live");
    assert!(
        attached.output_text().contains("already-there"),
        "attach output should replay existing screen state before live bytes; output={:?}",
        attached.output_text()
    );

    attached.write_line("from attach");
    attached.wait_for_output("from attach");

    let stop_output = run_harness(
        &home,
        &xdg,
        &["session", "tui", "stop", started.tui_id.as_str()],
    );
    assert!(
        stop_output.status.success(),
        "tui stop failed: {}",
        output_text(&stop_output)
    );
    attached.wait_for_exit();

    let bridge_stop_output = run_harness(&home, &xdg, &["bridge", "stop"]);
    assert!(
        bridge_stop_output.status.success(),
        "bridge stop failed: {}",
        output_text(&bridge_stop_output)
    );
    wait_for_child_exit(&mut bridge);

    daemon.kill().expect("kill daemon");
    wait_for_child_exit(&mut daemon);
}

fn wait_for_tui_screen_text(
    home: &Path,
    xdg: &Path,
    tui_id: &str,
    needle: &str,
) -> AgentTuiSnapshot {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let output = run_harness(home, xdg, &["session", "tui", "show", tui_id]);
        if output.status.success() {
            let snapshot: AgentTuiSnapshot =
                serde_json::from_slice(&output.stdout).expect("parse tui show");
            if snapshot.screen.text.contains(needle) {
                return snapshot;
            }
        }
        assert!(
            Instant::now() < deadline,
            "managed TUI never showed {:?}: {}",
            needle,
            output_text(&output)
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

struct AttachedTuiSession {
    child: Box<dyn portable_pty::Child + Send + Sync>,
    writer: Box<dyn Write + Send>,
    output: Arc<Mutex<Vec<u8>>>,
    reader_thread: Option<JoinHandle<()>>,
}

impl AttachedTuiSession {
    fn spawn(home: &Path, xdg: &Path, tui_id: &str) -> Self {
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: 30,
                cols: 120,
                pixel_width: 0,
                pixel_height: 0,
            })
            .expect("open attach PTY");
        let mut command = CommandBuilder::new(harness_binary());
        command.arg("session");
        command.arg("tui");
        command.arg("attach");
        command.arg(tui_id);
        command.env("HARNESS_HOST_HOME", home);
        command.env("HOME", home);
        command.env("XDG_DATA_HOME", xdg);
        let child = pair
            .slave
            .spawn_command(command)
            .expect("spawn attach child");
        drop(pair.slave);

        let mut reader = pair.master.try_clone_reader().expect("clone attach reader");
        let output = Arc::new(Mutex::new(Vec::new()));
        let reader_output = Arc::clone(&output);
        let reader_thread = std::thread::spawn(move || {
            let mut buffer = [0_u8; 4096];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(read) => {
                        reader_output
                            .lock()
                            .expect("attach output lock")
                            .extend_from_slice(&buffer[..read]);
                    }
                    Err(error) if error.kind() == ErrorKind::Interrupted => {}
                    Err(_) => break,
                }
            }
        });

        Self {
            child,
            writer: pair.master.take_writer().expect("take attach writer"),
            output,
            reader_thread: Some(reader_thread),
        }
    }

    fn write_line(&mut self, line: &str) {
        self.writer
            .write_all(line.as_bytes())
            .and_then(|()| self.writer.write_all(b"\n"))
            .and_then(|()| self.writer.flush())
            .expect("write attach input");
    }

    fn wait_for_output(&self, needle: &str) {
        let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
        loop {
            if self.output_text().contains(needle) {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "attach output never contained {:?}; output={:?}",
                needle,
                self.output_text()
            );
            thread::sleep(DAEMON_WAIT_INTERVAL);
        }
    }

    fn output_text(&self) -> String {
        String::from_utf8_lossy(&self.output.lock().expect("attach output lock")).into_owned()
    }

    fn wait_for_exit(&mut self) {
        let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
        loop {
            if self.child.try_wait().expect("poll attach child").is_some() {
                if let Some(reader_thread) = self.reader_thread.take() {
                    reader_thread.join().expect("join attach reader thread");
                }
                return;
            }
            assert!(
                Instant::now() < deadline,
                "attach child did not exit before timeout; output={:?}",
                self.output_text()
            );
            thread::sleep(DAEMON_WAIT_INTERVAL);
        }
    }
}

impl Drop for AttachedTuiSession {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(reader_thread) = self.reader_thread.take() {
            let _ = reader_thread.join();
        }
    }
}
