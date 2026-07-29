use std::fs::OpenOptions;
#[cfg(test)]
use std::io::{Read, Write};
#[cfg(test)]
use std::net::{TcpListener, TcpStream};
#[cfg(test)]
use std::thread;

use fs2::FileExt;

use crate::daemon::state;
use crate::daemon::state::{
    DaemonManifest, DaemonOwnership, HostBridgeManifest, ScopedDaemonRootOverride,
};

/// # Panics
/// Panics if any fixture directory, lock file, token file, or manifest
/// cannot be created or written, or if the daemon singleton lock is already
/// held.
#[must_use]
pub fn install_fake_running_xdg_daemon(
    xdg_root: &std::path::Path,
    endpoint: &str,
    token: &str,
) -> std::fs::File {
    let home = xdg_root.join("home");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(xdg_root).expect("create xdg");

    let daemon_root = xdg_root
        .join("harness")
        .join("daemon")
        .join(state::daemon_ownership_from_env_or_default().as_str());
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

    // Some callers write these fixture files before the environment even
    // points `daemon_root()` at `xdg_root` (proving discovery reacts to a
    // later environment change), so pin the write target explicitly rather
    // than relying on ambient env state.
    let _root_override = ScopedDaemonRootOverride::set(Some(daemon_root.clone()));
    let token_path = state::auth_token_path();
    std::fs::write(&token_path, token).expect("write token");
    state::write_manifest(&DaemonManifest {
        version: env!("CARGO_PKG_VERSION").to_string(),
        pid: std::process::id(),
        endpoint: endpoint.to_string(),
        started_at: "2026-04-11T00:00:00Z".to_string(),
        token_path: token_path.display().to_string(),
        sandboxed: false,
        host_bridge: HostBridgeManifest::default(),
        revision: 0,
        updated_at: String::new(),
        binary_stamp: None,
        ownership: DaemonOwnership::default(),
    })
    .expect("write manifest");

    lock_file
}

// Only this crate's own `#[cfg(test)]` unit tests call these three; the
// `tests/integration_daemon.rs` scenarios that need the module in a
// non-test, `daemon-runtime` build only reach `install_fake_running_xdg_daemon`
// above and bring their own request/response helpers.
#[cfg(test)]
pub(crate) fn fake_running_xdg_daemon(
    xdg_root: &std::path::Path,
    token: &str,
) -> (String, std::fs::File, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let token_value = token.to_string();
    let server = thread::spawn(move || {
        for _ in 0..2 {
            let (mut stream, _) = listener.accept().expect("accept");
            let request = read_http_request(&mut stream);
            let request_lower = request.to_ascii_lowercase();
            assert!(
                request_lower.contains(&format!(
                    "authorization: bearer {}",
                    token_value.to_ascii_lowercase()
                )),
                "missing bearer auth: {request}"
            );
            if request.starts_with("GET /v1/health ") {
                write_http_response(&mut stream, "200 OK", "text/plain", "ok");
                continue;
            }
            if request.starts_with("GET /v1/ready ") {
                write_http_response(
                    &mut stream,
                    "200 OK",
                    "application/json",
                    "{\"ready\":true,\"daemon_epoch\":\"test\"}",
                );
                continue;
            }
            assert!(
                request.starts_with("GET /v1/sessions "),
                "unexpected probe request: {request}"
            );
            write_http_response(&mut stream, "200 OK", "application/json", "[]");
        }
    });

    let lock_file = install_fake_running_xdg_daemon(xdg_root, &endpoint, token);
    (endpoint, lock_file, server)
}

#[cfg(test)]
pub(crate) fn read_http_request(stream: &mut TcpStream) -> String {
    stream.set_nonblocking(false).expect("blocking stream");
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(1)))
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
    String::from_utf8(buffer).expect("utf8 request")
}

#[cfg(test)]
pub(crate) fn write_http_response(
    stream: &mut TcpStream,
    status: &str,
    content_type: &str,
    body: &str,
) {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(response.as_bytes())
        .expect("write response");
    stream.flush().expect("flush response");
}
