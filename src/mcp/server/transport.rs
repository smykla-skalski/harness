use std::io;

use async_trait::async_trait;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};
use tracing::warn;

use crate::mcp::protocol::{
    ErrorCode, ErrorObject, Notification, Request, RequestId, Response,
};
use crate::mcp::server::incoming::IncomingMessage;

/// Contract for an MCP request/notification handler.
#[async_trait]
pub trait RequestHandler: Send + Sync {
    async fn handle_request(&self, request: Request) -> Response;
    async fn handle_notification(&self, notification: Notification);
}

/// Drive the MCP stdio loop against any async reader/writer pair. Reads
/// newline-delimited JSON-RPC messages, dispatches requests through the
/// handler, writes responses back as NDJSON. Returns when the reader hits
/// EOF or yields a terminal error.
///
/// # Errors
/// Returns any underlying I/O error from the reader or writer.
pub async fn serve<R, W, H>(mut reader: R, mut writer: W, handler: H) -> io::Result<()>
where
    R: AsyncBufRead + Unpin + Send,
    W: AsyncWrite + Unpin + Send,
    H: RequestHandler,
{
    let mut line = String::new();
    loop {
        line.clear();
        let bytes = reader.read_line(&mut line).await?;
        if bytes == 0 {
            return Ok(());
        }
        let trimmed = line.trim_end_matches(['\n', '\r']);
        if trimmed.is_empty() {
            continue;
        }
        dispatch_line(trimmed, &handler, &mut writer).await?;
    }
}

async fn dispatch_line<H, W>(line: &str, handler: &H, writer: &mut W) -> io::Result<()>
where
    H: RequestHandler,
    W: AsyncWrite + Unpin + Send,
{
    match IncomingMessage::parse(line) {
        Ok(IncomingMessage::Request(request)) => dispatch_request(handler, writer, request).await,
        Ok(IncomingMessage::Notification(note)) => {
            handler.handle_notification(note).await;
            Ok(())
        }
        Err(error) => dispatch_parse_error(writer, &error).await,
    }
}

async fn dispatch_request<H, W>(
    handler: &H,
    writer: &mut W,
    request: Request,
) -> io::Result<()>
where
    H: RequestHandler,
    W: AsyncWrite + Unpin + Send,
{
    let response = handler.handle_request(request).await;
    write_response(writer, &response).await
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn dispatch_parse_error<W>(writer: &mut W, error: &serde_json::Error) -> io::Result<()>
where
    W: AsyncWrite + Unpin + Send,
{
    warn!(%error, "failed to parse MCP message");
    let response = Response::error(
        RequestId::Number(0),
        ErrorObject::new(ErrorCode::ParseError, error.to_string()),
    );
    write_response(writer, &response).await
}

async fn write_response<W>(writer: &mut W, response: &Response) -> io::Result<()>
where
    W: AsyncWrite + Unpin + Send,
{
    let mut encoded =
        serde_json::to_vec(response).map_err(|error| io::Error::other(error.to_string()))?;
    encoded.push(b'\n');
    writer.write_all(&encoded).await?;
    writer.flush().await?;
    Ok(())
}
