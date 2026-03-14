use std::path::PathBuf;

use crate::errors::CliError;

/// Choose the install directory for the harness wrapper.
///
/// # Errors
/// Returns `CliError` if no suitable directory is found.
pub fn choose_install_dir(_path_env: &str) -> Result<(PathBuf, bool), CliError> {
    todo!()
}

/// Install the harness wrapper script.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn install_wrapper(_target_dir: &PathBuf) -> Result<PathBuf, CliError> {
    todo!()
}

/// Bootstrap main entry point.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn main(_argv: Option<&[String]>) -> Result<i32, CliError> {
    todo!()
}

#[cfg(test)]
mod tests {}
