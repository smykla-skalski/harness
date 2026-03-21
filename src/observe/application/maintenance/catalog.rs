use std::io::{self, Write};

use crate::errors::{CliError, CliErrorKind};
use crate::observe::types::{FOCUS_PRESETS, IssueCategory};

pub(in crate::observe::application) fn execute_list_categories() -> Result<i32, CliError> {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    for category in IssueCategory::ALL {
        writeln!(out, "{}: {}", category, category.description())
            .map_err(|error| CliErrorKind::session_parse_error(format!("write error: {error}")))?;
    }
    Ok(0)
}

pub(in crate::observe::application) fn execute_list_focus_presets() -> Result<i32, CliError> {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    for preset in FOCUS_PRESETS {
        writeln!(out, "{}: {}", preset.name, preset.description)
            .map_err(|error| CliErrorKind::session_parse_error(format!("write error: {error}")))?;
    }
    Ok(0)
}
