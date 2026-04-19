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
use crate::errors::{CliError, CliErrorKind};

use crate::session::transport::support::daemon_client;

#[derive(Debug, Clone, Args)]
pub struct ManagedAgentAttachArgs {
    /// Managed terminal agent ID.
    pub agent_id: String,
}

impl Execute for ManagedAgentAttachArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        self.run_attach()
    }
}

impl ManagedAgentAttachArgs {
    #[expect(clippy::too_many_lines, reason = "tokio select proxying loop")]
    fn run_attach(&self) -> Result<i32, CliError> {
        let client = daemon_client()?;
        let endpoint = client.endpoint().trim_end_matches('/');
        let ws_url = format!(
            "{}/v1/managed-agents/{}/attach",
            endpoint.replace("http://", "ws://"),
            self.agent_id
        );

        let mut request = ws_url.into_client_request().map_err(|error| {
            CliErrorKind::workflow_io(format!("invalid websocket URL: {error}"))
        })?;
        request.headers_mut().insert(
            "Authorization",
            format!("Bearer {}", client.token())
                .parse()
                .map_err(|error| {
                    CliErrorKind::workflow_io(format!("invalid auth header: {error}"))
                })?,
        );

        let runtime = runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| CliErrorKind::workflow_io(error.to_string()))?;

        runtime.block_on(async move {
            let (ws_stream, _) = match connect_async(request).await {
                Ok(result) => result,
                Err(TungsteniteError::Http(response)) => {
                    let body = response
                        .body()
                        .as_ref()
                        .map(|bytes| String::from_utf8_lossy(bytes).into_owned())
                        .unwrap_or_default();
                    if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&body)
                        && let Some(error) = parsed.get("error")
                    {
                        let message = error
                            .get("message")
                            .and_then(|value| value.as_str())
                            .unwrap_or("unknown error");
                        let code = error
                            .get("code")
                            .and_then(|value| value.as_str())
                            .unwrap_or("WORKFLOW_IO");
                        return Err(CliError::from(CliErrorKind::workflow_io(format!(
                            "[{code}] {message}"
                        ))));
                    }
                    return Err(CliError::from(CliErrorKind::workflow_io(format!(
                        "failed to connect to daemon websocket: HTTP error {}: {body}",
                        response.status()
                    ))));
                }
                Err(error) => {
                    return Err(CliError::from(CliErrorKind::workflow_io(format!(
                        "failed to connect to daemon websocket: {error}"
                    ))));
                }
            };

            enable_raw_mode()
                .map_err(|error| CliErrorKind::workflow_io(format!("enable raw mode: {error}")))?;

            let (mut write_half, mut read_half) = ws_stream.split();
            let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();

            thread::spawn(move || {
                let mut stdin_handle = stdin();
                let mut buffer = [0u8; 1024];
                loop {
                    match stdin_handle.read(&mut buffer) {
                        Ok(0) | Err(_) => break,
                        Ok(read) => {
                            if tx.send(buffer[..read].to_vec()).is_err() {
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
            while let Some(message) = read_half.next().await {
                match message {
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
