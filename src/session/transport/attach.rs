use std::io::{Read, Write, stdin, stdout};
use std::thread;

use clap::Args;
use crossterm::terminal::{disable_raw_mode, enable_raw_mode};
use futures_util::{SinkExt, StreamExt};
use tokio::runtime;
use tokio::sync::mpsc;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::{Error as TungsteniteError, Message};

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::client::DaemonClient;
use crate::errors::{CliError, CliErrorKind};

#[derive(Debug, Clone, Args)]
pub struct TuiAttachArgs {
    /// Managed TUI ID to attach to.
    pub tui_id: String,
}

impl Execute for TuiAttachArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        self.run_attach()
    }
}

impl TuiAttachArgs {
    #[expect(clippy::too_many_lines, reason = "tokio select proxying loop")]
    fn run_attach(&self) -> Result<i32, CliError> {
        let client = DaemonClient::try_connect()
            .ok_or_else(|| CliErrorKind::workflow_io("harness daemon is not running"))?;

        let endpoint = client.endpoint().trim_end_matches('/');
        let ws_url = format!(
            "{}/v1/agent-tuis/{}/attach",
            endpoint.replace("http://", "ws://"),
            self.tui_id
        );

        let mut request = ws_url
            .into_client_request()
            .map_err(|e| CliErrorKind::workflow_io(format!("invalid websocket URL: {e}")))?;
        request.headers_mut().insert(
            "Authorization",
            format!("Bearer {}", client.token())
                .parse()
                .map_err(|e| CliErrorKind::workflow_io(format!("invalid auth header: {e}")))?,
        );

        let rt = runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| CliErrorKind::workflow_io(e.to_string()))?;

        rt.block_on(async move {
            let (ws_stream, _) = match connect_async(request).await {
                Ok(res) => res,
                Err(TungsteniteError::Http(response)) => {
                    let body = response
                        .body()
                        .as_ref()
                        .map(|b| String::from_utf8_lossy(b).into_owned())
                        .unwrap_or_default();
                    if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&body)
                        && let Some(error) = parsed.get("error")
                    {
                        let msg = error
                            .get("message")
                            .and_then(|v| v.as_str())
                            .unwrap_or("unknown error");
                        let code = error
                            .get("code")
                            .and_then(|v| v.as_str())
                            .unwrap_or("WORKFLOW_IO");
                        return Err(CliError::from(CliErrorKind::workflow_io(format!(
                            "[{code}] {msg}"
                        ))));
                    }
                    return Err(CliError::from(CliErrorKind::workflow_io(format!(
                        "failed to connect to daemon websocket: HTTP error {}: {body}",
                        response.status()
                    ))));
                }
                Err(e) => {
                    return Err(CliError::from(CliErrorKind::workflow_io(format!(
                        "failed to connect to daemon websocket: {e}"
                    ))));
                }
            };

            // Only enable raw mode after a successful connection to prevent mangled logs on errors
            enable_raw_mode()
                .map_err(|e| CliErrorKind::workflow_io(format!("enable raw mode: {e}")))?;

            let (mut write_half, mut read_half) = ws_stream.split();
            let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();

            thread::spawn(move || {
                let mut stdin_handle = stdin();
                let mut buffer = [0u8; 1024];
                loop {
                    match stdin_handle.read(&mut buffer) {
                        Ok(0) | Err(_) => break, // EOF or error
                        Ok(n) => {
                            if tx.send(buffer[..n].to_vec()).is_err() {
                                break;
                            }
                        }
                    }
                }
            });

            tokio::spawn(async move {
                while let Some(bytes) = rx.recv().await {
                    if write_half
                        .send(Message::Binary(bytes.into()))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
            });

            let mut stdout_handle = stdout();
            while let Some(msg) = read_half.next().await {
                match msg {
                    Ok(Message::Binary(bytes)) => {
                        if stdout_handle.write_all(&bytes).is_err() {
                            break;
                        }
                        let _ = stdout_handle.flush();
                    }
                    Ok(Message::Text(text)) => {
                        if stdout_handle.write_all(text.as_bytes()).is_err() {
                            break;
                        }
                        let _ = stdout_handle.flush();
                    }
                    _ => break,
                }
            }

            let _ = disable_raw_mode();
            Ok::<(), CliError>(())
        })?;

        Ok(0)
    }
}
