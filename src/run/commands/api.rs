use clap::{Args, Subcommand};

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec::HttpMethod;
use crate::run::args::RunDirArgs;

use super::shared::resolve_run_application;

impl Execute for ApiArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        api(&self.method)
    }
}

/// HTTP method for `harness run kuma api` requests.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum ApiMethod {
    /// Send a GET request.
    Get {
        /// API path (e.g. /meshes or /zones).
        path: String,
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },
    /// Send a POST request with a JSON body.
    Post {
        /// API path (e.g. /tokens/dataplane).
        path: String,
        /// JSON request body.
        #[arg(long)]
        body: String,
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },
    /// Send a PUT request with a JSON body.
    Put {
        /// API path (e.g. /meshes/default/meshtrafficpermissions/allow-all).
        path: String,
        /// JSON request body.
        #[arg(long)]
        body: String,
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },
    /// Send a DELETE request.
    Delete {
        /// API path (e.g. /meshes/default/meshtrafficpermissions/allow-all).
        path: String,
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },
}

/// Arguments for `harness run kuma api`.
#[derive(Debug, Clone, Args)]
pub struct ApiArgs {
    /// HTTP method and path.
    #[command(subcommand)]
    pub method: ApiMethod,
}

/// Call the Kuma control plane REST API directly.
///
/// Resolves the CP address and admin token from the run context, makes the
/// requested HTTP call, and prints the response body to stdout. JSON responses
/// are pretty-printed; plain text is printed as-is.
///
/// # Errors
/// Returns `CliError` when the run context cannot be loaded, the request
/// fails, or the response body cannot be read.
pub fn api(method: &ApiMethod) -> Result<i32, CliError> {
    let (run_dir_args, path) = method_run_dir_and_path(method);
    let run = resolve_run_application(run_dir_args)?;

    // All methods read the response as raw text since the CP API sometimes
    // returns plain text (e.g., token endpoints) rather than JSON.
    let response_text = match method {
        ApiMethod::Get { .. } => run.call_control_plane_text(path, HttpMethod::Get, None)?,
        ApiMethod::Post { body, .. } => {
            let parsed = parse_json_body(body)?;
            run.call_control_plane_text(path, HttpMethod::Post, Some(&parsed))?
        }
        ApiMethod::Put { body, .. } => {
            let parsed = parse_json_body(body)?;
            run.call_control_plane_text(path, HttpMethod::Put, Some(&parsed))?
        }
        ApiMethod::Delete { .. } => run.call_control_plane_text(path, HttpMethod::Delete, None)?,
    };

    // Try to pretty-print as JSON, fall back to raw text.
    let output = match serde_json::from_str::<serde_json::Value>(&response_text) {
        Ok(value) => serde_json::to_string_pretty(&value).unwrap_or_else(|_| response_text.clone()),
        Err(_) => response_text,
    };

    println!("{output}");
    Ok(0)
}

/// Extract run-dir arguments and the API path from any method variant.
fn method_run_dir_and_path(method: &ApiMethod) -> (&RunDirArgs, &str) {
    match method {
        ApiMethod::Get { path, run_dir, .. }
        | ApiMethod::Post { path, run_dir, .. }
        | ApiMethod::Put { path, run_dir, .. }
        | ApiMethod::Delete { path, run_dir, .. } => (run_dir, path),
    }
}

/// Parse a JSON string into a `serde_json::Value`.
///
/// # Errors
/// Returns `CliError` when the string is not valid JSON.
fn parse_json_body(raw: &str) -> Result<serde_json::Value, CliError> {
    serde_json::from_str(raw).map_err(|e| {
        CliError::from(CliErrorKind::usage_error(format!(
            "invalid JSON in --body: {e}"
        )))
    })
}

#[cfg(test)]
#[path = "api/tests.rs"]
mod tests;
