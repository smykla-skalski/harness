use std::fs::OpenOptions;
use std::net::TcpListener;
use std::thread;

use fs2::FileExt;

use super::DaemonClient;
use super::connection::try_build_client;
use super::test_support::{fake_running_xdg_daemon, read_http_request, write_http_response};
use crate::daemon::state::{self, DaemonManifest, HostBridgeManifest};
use crate::daemon::transport::HARNESS_MONITOR_APP_GROUP_ID;

#[test]
fn try_build_client_requires_authenticated_api_readiness() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    let xdg_str = xdg.to_str().expect("utf8 xdg").to_string();
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));

    let server = thread::spawn(move || {
        for request_index in 0..3 {
            let (mut stream, _) = listener.accept().expect("accept");
            let request = read_http_request(&mut stream);
            let request_lower = request.to_ascii_lowercase();
            assert!(
                request_lower.contains("authorization: bearer test-token"),
                "missing bearer auth: {request}"
            );
            if request.starts_with("GET /v1/health ") {
                write_http_response(&mut stream, "200 OK", "text/plain", "ok");
                continue;
            }
            assert!(
                request.starts_with("GET /v1/ready "),
                "unexpected probe request: {request}"
            );
            let status = if request_index == 1 {
                "503 Service Unavailable"
            } else {
                "200 OK"
            };
            let body = if request_index == 1 {
                "{\"error\":\"warming up\"}"
            } else {
                "{\"ready\":true,\"daemon_epoch\":\"test\"}"
            };
            write_http_response(&mut stream, status, "application/json", body);
        }
    });

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg_str.as_str())),
            ("HOME", Some(home.to_str().expect("utf8 home"))),
            ("HARNESS_HOST_HOME", Some(home.to_str().expect("utf8 home"))),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_DAEMON_DATA_HOME", None),
        ],
        || {
            std::fs::create_dir_all(&xdg).expect("create xdg");
            let daemon_root = state::daemon_root();
            std::fs::create_dir_all(&daemon_root).expect("create daemon root");
            let lock_path = daemon_root.join(state::DAEMON_LOCK_FILE);
            let lock_file = OpenOptions::new()
                .create(true)
                .read(true)
                .write(true)
                .truncate(false)
                .open(&lock_path)
                .expect("open daemon lock");
            lock_file
                .try_lock_exclusive()
                .expect("hold daemon singleton lock");
            let token_path = state::auth_token_path();
            std::fs::create_dir_all(token_path.parent().expect("token parent"))
                .expect("create daemon dir");
            std::fs::write(&token_path, "test-token").expect("write token");

            let manifest = DaemonManifest {
                version: env!("CARGO_PKG_VERSION").to_string(),
                pid: std::process::id(),
                endpoint: endpoint.clone(),
                started_at: "2026-04-11T00:00:00Z".to_string(),
                token_path: token_path.display().to_string(),
                sandboxed: false,
                host_bridge: HostBridgeManifest::default(),
                revision: 0,
                updated_at: String::new(),
                binary_stamp: None,
            };
            state::write_manifest(&manifest).expect("write manifest");

            let client = try_build_client();
            assert!(client.is_some(), "authenticated session API should warm up");
        },
    );

    server.join().expect("server");
}

#[test]
fn try_build_client_discovers_running_app_group_daemon_when_default_root_is_empty() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let app_group_root = home
        .join("Library")
        .join("Group Containers")
        .join(HARNESS_MONITOR_APP_GROUP_ID)
        .join("harness")
        .join("daemon");
    std::fs::create_dir_all(&app_group_root).expect("create app group daemon root");

    let lock_path = app_group_root.join(state::DAEMON_LOCK_FILE);
    let lock_file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(&lock_path)
        .expect("open daemon lock");
    lock_file
        .try_lock_exclusive()
        .expect("hold daemon singleton lock");

    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let server = thread::spawn(move || {
        for request_index in 0..3 {
            let (mut stream, _) = listener.accept().expect("accept");
            let request = read_http_request(&mut stream);
            let request_lower = request.to_ascii_lowercase();
            assert!(
                request_lower.contains("authorization: bearer test-token"),
                "missing bearer auth: {request}"
            );
            if request.starts_with("GET /v1/health ") {
                write_http_response(&mut stream, "200 OK", "text/plain", "ok");
                continue;
            }
            assert!(
                request.starts_with("GET /v1/ready "),
                "unexpected probe request: {request}"
            );
            let status = if request_index == 1 {
                "503 Service Unavailable"
            } else {
                "200 OK"
            };
            let body = if request_index == 1 {
                "{\"error\":\"warming up\"}"
            } else {
                "{\"ready\":true,\"daemon_epoch\":\"test\"}"
            };
            write_http_response(&mut stream, status, "application/json", body);
        }
    });

    temp_env::with_vars(
        [
            ("HARNESS_HOST_HOME", Some(home.to_str().expect("utf8 home"))),
            ("HOME", Some(home.to_str().expect("utf8 home"))),
            ("XDG_DATA_HOME", Some(xdg.to_str().expect("utf8 xdg"))),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_DAEMON_DATA_HOME", None),
        ],
        || {
            std::fs::write(app_group_root.join("auth-token"), "test-token").expect("write token");
            let manifest = DaemonManifest {
                version: env!("CARGO_PKG_VERSION").to_string(),
                pid: std::process::id(),
                endpoint: endpoint.clone(),
                started_at: "2026-04-11T00:00:00Z".to_string(),
                token_path: app_group_root.join("auth-token").display().to_string(),
                sandboxed: true,
                host_bridge: HostBridgeManifest::default(),
                revision: 0,
                updated_at: String::new(),
                binary_stamp: None,
            };
            std::fs::write(
                app_group_root.join("manifest.json"),
                serde_json::to_string_pretty(&manifest).expect("serialize manifest"),
            )
            .expect("write manifest");

            let client = try_build_client().expect("discover running app group daemon");
            assert_eq!(client.endpoint, endpoint);
            assert_eq!(client.token, "test-token");
            assert_eq!(
                state::daemon_root(),
                xdg.join("harness").join("daemon"),
                "daemon client discovery must not mutate the process root"
            );
        },
    );

    server.join().expect("server");
}

#[test]
fn try_connect_rebuilds_after_environment_changes() {
    let first = tempfile::tempdir().expect("first tempdir");
    let second = tempfile::tempdir().expect("second tempdir");

    let (first_endpoint, first_lock, first_server) =
        fake_running_xdg_daemon(first.path(), "first-token");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(first.path().to_str().expect("utf8 xdg")),
            ),
            (
                "HOME",
                Some(first.path().join("home").to_str().expect("utf8 home")),
            ),
            (
                "HARNESS_HOST_HOME",
                Some(first.path().join("home").to_str().expect("utf8 home")),
            ),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_DAEMON_DATA_HOME", None),
        ],
        || {
            let client = DaemonClient::try_connect().expect("first daemon client");
            assert_eq!(client.endpoint, first_endpoint);
            assert_eq!(client.token, "first-token");
        },
    );
    drop(first_lock);
    first_server.join().expect("first server");

    let (second_endpoint, second_lock, second_server) =
        fake_running_xdg_daemon(second.path(), "second-token");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(second.path().to_str().expect("utf8 xdg")),
            ),
            (
                "HOME",
                Some(second.path().join("home").to_str().expect("utf8 home")),
            ),
            (
                "HARNESS_HOST_HOME",
                Some(second.path().join("home").to_str().expect("utf8 home")),
            ),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_DAEMON_DATA_HOME", None),
        ],
        || {
            let client = DaemonClient::try_connect().expect("second daemon client");
            assert_eq!(client.endpoint, second_endpoint);
            assert_eq!(client.token, "second-token");
        },
    );
    drop(second_lock);
    second_server.join().expect("second server");
}
