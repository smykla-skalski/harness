use std::time::Duration;

use backoff::ExponentialBackoff;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;

use crate::errors::{CliError, CliErrorKind};

use super::container::docker_exec_cmd;

/// Extract the admin user token from a running CP container.
///
/// The CP stores the admin token in the global-secrets endpoint.
/// Since `localhostIsAdmin` is true by default, we exec into the container
/// using busybox wget to fetch it from localhost.
///
/// # Errors
/// Returns `CliError` if the token cannot be extracted.
pub fn extract_admin_token(cp_container: &str) -> Result<String, CliError> {
    // The CP bootstraps the admin token asynchronously after startup.
    // Use exponential backoff: starts at 200ms, caps at 2s, gives up after 15s.
    let backoff_config = ExponentialBackoff {
        initial_interval: Duration::from_millis(200),
        max_interval: Duration::from_secs(2),
        max_elapsed_time: Some(Duration::from_secs(15)),
        ..ExponentialBackoff::default()
    };

    backoff::retry(
        backoff_config,
        || -> Result<String, backoff::Error<Box<CliError>>> {
            let result = docker_exec_cmd(
                cp_container,
                &[
                    "/busybox/wget",
                    "-q",
                    "-O",
                    "-",
                    "http://localhost:5681/global-secrets/admin-user-token",
                ],
            )
            .map_err(|e| backoff::Error::transient(Box::new(e)))?;

            let body = serde_json::from_str::<serde_json::Value>(result.stdout.trim()).map_err(
                |error| {
                    backoff::Error::transient(Box::new(CliError::from(CliErrorKind::serialize(
                        format!("invalid JSON in token response: {error}"),
                    ))))
                },
            )?;

            let b64_data = body["data"].as_str().ok_or_else(|| {
                backoff::Error::transient(Box::new(CliError::from(
                    CliErrorKind::token_generation_failed("missing data field"),
                )))
            })?;

            let bytes = STANDARD.decode(b64_data).map_err(|error| {
                backoff::Error::transient(Box::new(CliError::from(
                    CliErrorKind::token_generation_failed(format!("base64 decode failed: {error}")),
                )))
            })?;

            let token = String::from_utf8(bytes).map_err(|error| {
                backoff::Error::permanent(Box::new(CliError::from(
                    CliErrorKind::token_generation_failed(format!(
                        "invalid UTF-8 in token: {error}"
                    )),
                )))
            })?;

            if token.is_empty() {
                return Err(backoff::Error::transient(Box::new(CliError::from(
                    CliErrorKind::token_generation_failed("empty token"),
                ))));
            }

            Ok(token)
        },
    )
    .map_err(|error| {
        CliErrorKind::token_generation_failed(format!(
            "could not extract admin token within timeout: {error}"
        ))
        .into()
    })
}
