use std::env::current_exe;
use std::path::PathBuf;

use serde::Serialize;

use crate::errors::{CliError, CliErrorKind};

pub(super) fn running_controller_path() -> Result<PathBuf, CliError> {
    current_exe().map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "resolve running harness-systemd controller: {error}"
        )))
    })
}

pub(super) fn print_json<T: Serialize>(value: &T) -> Result<(), CliError> {
    let rendered = serde_json::to_string_pretty(value).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "serialize systemd response: {error}"
        )))
    })?;
    println!("{rendered}");
    Ok(())
}
