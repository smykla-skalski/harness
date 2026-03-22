use std::sync::Arc;

use crate::errors::CliError;
use crate::infra::blocks::kuma::token;
use crate::infra::blocks::{StdProcessExecutor, container_runtime_from_env};

/// Extract the admin user token from a running CP container.
///
/// The CP stores the admin token in the global-secrets endpoint.
/// Since `localhostIsAdmin` is true by default, we exec into the container
/// using busybox wget to fetch it from localhost.
///
/// # Errors
/// Returns `CliError` if the token cannot be extracted.
pub fn extract_admin_token(cp_container: &str) -> Result<String, CliError> {
    let docker = container_runtime_from_env(Arc::new(StdProcessExecutor))?;
    token::extract_admin_token(docker.as_ref(), cp_container).map_err(Into::into)
}
