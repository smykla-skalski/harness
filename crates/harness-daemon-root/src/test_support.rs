use std::fs::OpenOptions;
#[cfg(any(test, feature = "test-support"))]
use std::io::{Read, Write};
#[cfg(any(test, feature = "test-support"))]
use std::net::TcpStream;

use fs2::FileExt;

use super::{
    DAEMON_LOCK_FILE, DaemonManifest, DaemonOwnership, HostBridgeManifest,
    ScopedDaemonRootOverride, auth_token_path, daemon_ownership_from_env_or_default,
    write_manifest,
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
        .join(daemon_ownership_from_env_or_default().as_str());
    std::fs::create_dir_all(&daemon_root).expect("create daemon root");
    let lock_file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(daemon_root.join(DAEMON_LOCK_FILE))
        .expect("open daemon lock");
    lock_file
        .try_lock_exclusive()
        .expect("hold daemon singleton lock");

    // Some callers write these fixture files before the environment even
    // points `daemon_root()` at `xdg_root` (proving discovery reacts to a
    // later environment change), so pin the write target explicitly rather
    // than relying on ambient env state.
    let _root_override = ScopedDaemonRootOverride::set(Some(daemon_root.clone()));
    let token_path = auth_token_path();
    std::fs::write(&token_path, token).expect("write token");
    write_manifest(&DaemonManifest {
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

/// `harness-daemon`'s own `direct_session_start` unit test calls these two;
/// the `tests/integration_daemon.rs` scenarios that need this fixture in a
/// non-test, `daemon-runtime` build only reach `install_fake_running_xdg_daemon`
/// above and bring their own request/response helpers. `pub`, not
/// `pub(crate)`, and gated by `test-support` rather than `daemon-runtime`
/// since that caller is `harness-daemon`'s own `cfg(test)` unit test, in a
/// different crate that never sees this crate's `cfg(test)`.
///
/// # Panics
/// Panics if the stream cannot be read or the request is not valid UTF-8.
#[cfg(any(test, feature = "test-support"))]
pub fn read_http_request(stream: &mut TcpStream) -> String {
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

/// # Panics
/// Panics if the response cannot be written to the stream.
#[cfg(any(test, feature = "test-support"))]
pub fn write_http_response(stream: &mut TcpStream, status: &str, content_type: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(response.as_bytes())
        .expect("write response");
    stream.flush().expect("flush response");
}
