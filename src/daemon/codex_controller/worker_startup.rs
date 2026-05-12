use std::future::Future;
use std::time::Duration;

use serde_json::Value;
use tokio::time::timeout;

use crate::errors::{CliError, CliErrorKind};

use super::rpc::CodexJsonRpc;

pub(super) const STARTUP_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

pub(super) async fn startup_request(
    rpc: &mut CodexJsonRpc,
    method: &'static str,
    params: Value,
    label: &'static str,
) -> Result<Value, CliError> {
    with_startup_timeout(label, rpc.request(method, params)).await
}

pub(super) async fn with_startup_timeout<T, Fut>(
    label: &'static str,
    future: Fut,
) -> Result<T, CliError>
where
    Fut: Future<Output = Result<T, CliError>>,
{
    timeout(STARTUP_REQUEST_TIMEOUT, future)
        .await
        .map_err(|_| {
            CliErrorKind::workflow_io(format!(
                "codex app-server {label} did not respond within {}s",
                STARTUP_REQUEST_TIMEOUT.as_secs()
            ))
        })?
}
