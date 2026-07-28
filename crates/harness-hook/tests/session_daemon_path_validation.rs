//! Proves that `harness-hook`'s `session::daemon` request-path builders
//! reject an unsafe session id before any request reaches the daemon, the
//! same property the root crate's `session::service` daemon-routing tests
//! prove for its own copy of this pattern.
//!
//! `harness-hook`'s `[lib] test = false` means unit tests inside `src/`
//! never run, so this drives the public `session::service` wrapper instead
//! of the private `session::daemon` helper it delegates to.

use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;

use fs2::FileExt as _;
use harness_daemon_client::state::{self, DaemonManifest};
use harness_hook::session::service;

/// Writes the manifest, auth token, and singleton lock a real daemon would
/// leave behind, so `DaemonClient::try_connect()` discovers this fake
/// daemon exactly the way it discovers a live one.
fn install_fake_running_daemon(endpoint: &str, token: &str) -> std::fs::File {
    let daemon_root = state::daemon_root();
    std::fs::create_dir_all(&daemon_root).expect("create daemon root");
    let lock_file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(daemon_root.join(state::DAEMON_LOCK_FILE))
        .expect("open daemon lock");
    lock_file
        .try_lock_exclusive()
        .expect("hold daemon singleton lock");
    let token_path = daemon_root.join("auth-token");
    std::fs::write(&token_path, token).expect("write token");
    let manifest = DaemonManifest {
        endpoint: endpoint.to_string(),
        token_path: token_path.display().to_string(),
    };
    std::fs::write(
        daemon_root.join("manifest.json"),
        serde_json::to_string_pretty(&manifest).expect("serialize manifest"),
    )
    .expect("write manifest");
    lock_file
}

fn read_request(stream: &mut TcpStream) -> String {
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(2)))
        .expect("read timeout");
    let mut buffer = Vec::new();
    loop {
        let mut chunk = [0_u8; 1024];
        let read = stream.read(&mut chunk).expect("read request");
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
        if buffer.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
    }
    String::from_utf8_lossy(&buffer).into_owned()
}

fn write_response(stream: &mut TcpStream, body: &str) {
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(response.as_bytes())
        .expect("write response");
    stream.flush().expect("flush response");
}

fn request_fake_daemon_shutdown(endpoint: &str) {
    let addr = endpoint.trim_start_matches("http://");
    if let Ok(mut stream) = TcpStream::connect(addr) {
        let _ = stream.write_all(
            b"GET /v1/test-shutdown HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n",
        );
        let _ = stream.flush();
    }
}

#[test]
fn leave_session_rejects_a_session_id_that_would_escape_its_path_segment() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    std::fs::create_dir_all(&home).expect("create home");

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path())),
            ("HOME", Some(home.as_path())),
            ("HARNESS_HOST_HOME", Some(home.as_path())),
            ("HARNESS_DAEMON_DATA_HOME", None::<&Path>),
            ("HARNESS_APP_GROUP_ID", None::<&Path>),
        ],
        || {
            let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
            let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
            let token = "fake-daemon-token";
            let _lock = install_fake_running_daemon(&endpoint, token);

            let captured: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
            let captured_inner = Arc::clone(&captured);
            let handle = thread::spawn(move || {
                loop {
                    let Ok((mut stream, _)) = listener.accept() else {
                        return;
                    };
                    let request = read_request(&mut stream);
                    let first_line = request.lines().next().unwrap_or_default().to_string();
                    if first_line.starts_with("GET /v1/health") {
                        write_response(&mut stream, "ok");
                        continue;
                    }
                    if first_line.starts_with("GET /v1/ready") {
                        write_response(&mut stream, "{\"ready\":true,\"daemon_epoch\":\"t\"}");
                        continue;
                    }
                    if first_line.starts_with("GET /v1/test-shutdown") {
                        return;
                    }
                    *captured_inner.lock().expect("lock") = Some(first_line);
                    write_response(&mut stream, "{}");
                    return;
                }
            });

            let project = tmp.path().join("project");
            let error = service::leave_session("../orchestrator/stop", "agent-1", &project)
                .expect_err(
                    "a session id with a path separator must be rejected before any request is sent",
                );
            assert!(error.to_string().contains("../orchestrator/stop"));

            request_fake_daemon_shutdown(&endpoint);
            handle
                .join()
                .expect("fake daemon thread should exit cleanly after a shutdown request");
            let slot = captured.lock().expect("lock");
            assert!(
                slot.is_none(),
                "an id with a path separator or '..' must be rejected before any request is sent, \
                 but the daemon captured {:?}",
                slot.as_ref()
            );
        },
    );
}
