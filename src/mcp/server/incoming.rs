use serde::Deserialize;
use serde_json::Value;

use crate::mcp::protocol::{Notification, Request};

/// A single decoded JSON-RPC message off the wire. Requests carry an `id`;
/// notifications do not. We distinguish by checking for that field up front
/// rather than trying to parse as `Request` and falling back.
#[derive(Debug, Clone)]
pub enum IncomingMessage {
    Request(Request),
    Notification(Notification),
}

impl IncomingMessage {
    /// Parse a single JSON-RPC line into either a request or notification.
    ///
    /// # Errors
    /// Returns the underlying `serde_json::Error` if the line is not a valid
    /// JSON-RPC 2.0 message of either kind.
    pub fn parse(line: &str) -> Result<Self, serde_json::Error> {
        let raw: Value = serde_json::from_str(line)?;
        if raw.get("id").is_some() {
            let req: Request = serde_json::from_value(raw)?;
            Ok(Self::Request(req))
        } else {
            let note: Notification = Notification::deserialize(raw)?;
            Ok(Self::Notification(note))
        }
    }
}
