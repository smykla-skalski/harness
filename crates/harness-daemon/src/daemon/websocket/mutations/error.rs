use serde_json::Value;

use super::{CliError, WsErrorPayload, ws_error_payload_from_cli_error};

pub(crate) struct MutationError {
    pub(super) code: String,
    pub(super) message: String,
    pub(super) status_code: Option<u16>,
    pub(super) data: Option<Box<Value>>,
}

impl From<CliError> for MutationError {
    fn from(error: CliError) -> Self {
        let payload = ws_error_payload_from_cli_error(&error);
        Self {
            code: payload.code,
            message: payload.message,
            status_code: payload.status_code,
            data: payload.data.map(Box::new),
        }
    }
}

impl From<serde_json::Error> for MutationError {
    fn from(error: serde_json::Error) -> Self {
        Self {
            code: "INVALID_PARAMS".into(),
            message: format!("failed to parse request params: {error}"),
            status_code: None,
            data: None,
        }
    }
}

impl MutationError {
    pub(super) fn into_ws_error_payload(self) -> WsErrorPayload {
        WsErrorPayload {
            code: self.code,
            message: self.message,
            details: vec![],
            status_code: self.status_code,
            data: self.data.map(|data| *data),
        }
    }
}
