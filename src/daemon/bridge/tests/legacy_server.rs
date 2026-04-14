use std::io::{BufRead, BufReader, Write as _};
use std::path::PathBuf;
use std::thread;

use crate::errors::{CliError, CliErrorKind};

use super::{
    Arc, AtomicBool, BTreeMap, BridgeClient, BridgeEnvelope, BridgeRequest, BridgeResponse,
    BridgeState, BridgeStatusReport, Duration, HostBridgeCapabilityManifest, Ordering,
    StdUnixListener, fs, remove_if_exists, state, write_bridge_state,
};

#[derive(Debug, Clone, Copy)]
pub(super) enum LegacyShutdownBehavior {
    ExitAfter(Duration),
    Ignore,
}

#[derive(Debug)]
pub(super) struct LegacyBridgeServer {
    socket_path: PathBuf,
    token: String,
    terminate: Arc<AtomicBool>,
    join: Option<thread::JoinHandle<()>>,
}

impl LegacyBridgeServer {
    pub(super) fn start(
        capabilities: BTreeMap<String, HostBridgeCapabilityManifest>,
        shutdown_behavior: LegacyShutdownBehavior,
    ) -> Self {
        state::ensure_daemon_dirs().expect("dirs");
        let socket_path = state::daemon_root().join("legacy-bridge-test.sock");
        let token_path = state::daemon_root().join("legacy-bridge-token");
        let token = "legacy-bridge-token".to_string();
        let terminate = Arc::new(AtomicBool::new(false));
        let _ = remove_if_exists(&socket_path);
        fs::write(&token_path, &token).expect("write token");
        write_bridge_state(&BridgeState {
            socket_path: socket_path.display().to_string(),
            pid: 999_999_999,
            started_at: "2026-04-11T17:00:00Z".to_string(),
            token_path: token_path.display().to_string(),
            capabilities: capabilities.clone(),
        })
        .expect("write bridge state");

        let listener = StdUnixListener::bind(&socket_path).expect("bind legacy bridge socket");
        let report = BridgeStatusReport {
            running: true,
            socket_path: Some(socket_path.display().to_string()),
            pid: Some(999_999_999),
            started_at: Some("2026-04-11T17:00:00Z".to_string()),
            uptime_seconds: Some(1),
            capabilities,
        };
        let thread_socket_path = socket_path.clone();
        let thread_token = token.clone();
        let thread_terminate = Arc::clone(&terminate);
        let join = thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else {
                    break;
                };
                let mut line = String::new();
                BufReader::new(stream.try_clone().expect("clone stream"))
                    .read_line(&mut line)
                    .expect("read request");
                let envelope: BridgeEnvelope =
                    serde_json::from_str(&line).expect("parse bridge envelope");
                let request = envelope.request.clone();
                let response = if envelope.token != thread_token {
                    BridgeResponse::error(&CliError::from(CliErrorKind::workflow_io(
                        "bridge token mismatch",
                    )))
                } else {
                    match request {
                        BridgeRequest::Status => {
                            BridgeResponse::ok_payload(&report).expect("status response")
                        }
                        BridgeRequest::Shutdown => BridgeResponse::empty_ok(),
                        _ => BridgeResponse::error(&CliError::from(CliErrorKind::workflow_parse(
                            "unsupported legacy test request",
                        ))),
                    }
                };
                let payload = serde_json::to_string(&response).expect("serialize response");
                stream
                    .write_all(payload.as_bytes())
                    .expect("write response");
                stream.write_all(b"\n").expect("write newline");
                stream.flush().expect("flush response");

                if thread_terminate.load(Ordering::SeqCst) {
                    break;
                }
                if matches!(request, BridgeRequest::Shutdown) {
                    match shutdown_behavior {
                        LegacyShutdownBehavior::ExitAfter(delay) => {
                            thread::sleep(delay);
                            break;
                        }
                        LegacyShutdownBehavior::Ignore => {}
                    }
                }
            }
            let _ = std::fs::remove_file(&thread_socket_path);
        });

        Self {
            socket_path,
            token,
            terminate,
            join: Some(join),
        }
    }

    fn wake(&self) {
        let _ = BridgeClient {
            socket_path: self.socket_path.clone(),
            token: self.token.clone(),
        }
        .status();
    }
}

impl Drop for LegacyBridgeServer {
    fn drop(&mut self) {
        self.terminate.store(true, Ordering::SeqCst);
        self.wake();
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
        let _ = std::fs::remove_file(&self.socket_path);
    }
}
