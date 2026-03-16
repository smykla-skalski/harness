use clap::{Args, Subcommand};

use crate::commands::{RunDirArgs, resolve_run_context};
use crate::errors::{CliError, CliErrorKind};
use crate::exec::{self, HttpMethod};

/// HTTP method for `harness api` requests.
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

/// Arguments for `harness api`.
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
    let ctx = resolve_run_context(run_dir_args)?;
    let runtime = ctx.cluster_runtime()?;
    let access = runtime.control_plane_access()?;
    let token = access.admin_token.as_deref();

    // All methods read the response as raw text since the CP API sometimes
    // returns plain text (e.g., token endpoints) rather than JSON.
    let response_text = match method {
        ApiMethod::Get { .. } => {
            exec::cp_api_text(&access.addr, path, HttpMethod::Get, None, token)?
        }
        ApiMethod::Post { body, .. } => {
            let parsed = parse_json_body(body)?;
            exec::cp_api_text(&access.addr, path, HttpMethod::Post, Some(&parsed), token)?
        }
        ApiMethod::Put { body, .. } => {
            let parsed = parse_json_body(body)?;
            exec::cp_api_text(&access.addr, path, HttpMethod::Put, Some(&parsed), token)?
        }
        ApiMethod::Delete { .. } => {
            exec::cp_api_text(&access.addr, path, HttpMethod::Delete, None, token)?
        }
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
mod tests {
    use super::*;

    #[test]
    fn parse_json_body_valid() {
        let value = parse_json_body(r#"{"name":"test","mesh":"default"}"#).unwrap();
        assert_eq!(value["name"], "test");
        assert_eq!(value["mesh"], "default");
    }

    #[test]
    fn parse_json_body_invalid() {
        let result = parse_json_body("not json");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.message().contains("invalid JSON in --body"));
    }

    #[test]
    fn method_run_dir_and_path_get() {
        let run_dir = RunDirArgs {
            run_dir: None,
            run_id: None,
            run_root: None,
        };
        let method = ApiMethod::Get {
            path: "/zones".to_string(),
            run_dir,
        };
        let (_, path) = method_run_dir_and_path(&method);
        assert_eq!(path, "/zones");
    }

    #[test]
    fn method_run_dir_and_path_post() {
        let run_dir = RunDirArgs {
            run_dir: None,
            run_id: None,
            run_root: None,
        };
        let method = ApiMethod::Post {
            path: "/tokens/dataplane".to_string(),
            body: "{}".to_string(),
            run_dir,
        };
        let (_, path) = method_run_dir_and_path(&method);
        assert_eq!(path, "/tokens/dataplane");
    }

    #[test]
    fn method_run_dir_and_path_put() {
        let run_dir = RunDirArgs {
            run_dir: None,
            run_id: None,
            run_root: None,
        };
        let method = ApiMethod::Put {
            path: "/meshes/default".to_string(),
            body: "{}".to_string(),
            run_dir,
        };
        let (_, path) = method_run_dir_and_path(&method);
        assert_eq!(path, "/meshes/default");
    }

    #[test]
    fn method_run_dir_and_path_delete() {
        let run_dir = RunDirArgs {
            run_dir: None,
            run_id: None,
            run_root: None,
        };
        let method = ApiMethod::Delete {
            path: "/meshes/default/meshtrafficpermissions/allow-all".to_string(),
            run_dir,
        };
        let (_, path) = method_run_dir_and_path(&method);
        assert_eq!(path, "/meshes/default/meshtrafficpermissions/allow-all");
    }
}
