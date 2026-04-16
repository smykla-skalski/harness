use std::io::{BufRead, BufReader, Write as _};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::thread;

use tokio::runtime;
use tokio::sync::broadcast;

use crate::errors::{CliError, CliErrorKind};

use super::core::{BridgeEnvelope, BridgeHandleResult, BridgeResponse};
use super::server::BridgeServer;

pub(super) fn handle_stream(
    server: &Arc<BridgeServer>,
    stream: &UnixStream,
) -> Result<(), CliError> {
    let mut line = String::new();
    BufReader::new(
        stream
            .try_clone()
            .map_err(|error| CliErrorKind::workflow_io(format!("clone bridge stream: {error}")))?,
    )
    .read_line(&mut line)
    .map_err(|error| CliErrorKind::workflow_io(format!("read bridge request: {error}")))?;
    let result = match serde_json::from_str::<BridgeEnvelope>(&line) {
        Ok(envelope) => server.handle(envelope),
        Err(error) => {
            let error = CliError::from(CliErrorKind::workflow_parse(format!(
                "parse bridge request: {error}"
            )));
            BridgeHandleResult::Response(BridgeResponse::error(&error))
        }
    };

    let (response, stream_info) = match result {
        BridgeHandleResult::Response(resp) => (resp, None),
        BridgeHandleResult::AttachStream(resp, process, rx) => (resp, Some((process, rx))),
    };

    let payload = serde_json::to_string(&response)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    let mut writer = stream
        .try_clone()
        .map_err(|error| CliErrorKind::workflow_io(format!("clone bridge writer: {error}")))?;
    writer
        .write_all(payload.as_bytes())
        .and_then(|()| writer.write_all(b"\n"))
        .and_then(|()| writer.flush())
        .map_err(|error| CliErrorKind::workflow_io(format!("write bridge response: {error}")))?;

    if let Some((process, attach_state)) = stream_info {
        // Output proxy: Broadcast -> Socket
        let mut output_writer = stream
            .try_clone()
            .map_err(|error| CliErrorKind::workflow_io(format!("clone bridge writer: {error}")))?;
        if !attach_state.initial_bytes.is_empty() {
            output_writer
                .write_all(&attach_state.initial_bytes)
                .and_then(|()| output_writer.flush())
                .map_err(|error| {
                    CliErrorKind::workflow_io(format!("write bridge replay bytes: {error}"))
                })?;
        }
        let mut rx = attach_state.broadcast_rx;
        thread::spawn(move || {
            let Ok(rt) = runtime::Builder::new_current_thread().enable_all().build() else {
                return;
            };
            rt.block_on(async move {
                loop {
                    match rx.recv().await {
                        Ok(bytes) => {
                            if output_writer.write_all(&bytes).is_err()
                                || output_writer.flush().is_err()
                            {
                                break;
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(_)) => {}
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
                let _ = output_writer.shutdown(Shutdown::Both);
            });
        });

        // Input proxy: Socket -> PTY
        let mut input_reader = stream
            .try_clone()
            .map_err(|error| CliErrorKind::workflow_io(format!("clone bridge reader: {error}")))?;
        thread::spawn(move || {
            let mut buffer = [0u8; 1024];
            loop {
                use std::io::Read;
                match input_reader.read(&mut buffer) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if process.write_bytes(&buffer[..n]).is_err() {
                            break;
                        }
                    }
                }
            }
            let _ = input_reader.shutdown(Shutdown::Both);
        });
    }

    Ok(())
}
