use std::io::{self, Write};

use crate::types::IssueCategory;
use harness_kernel::errors::{CliError, CliErrorKind};

pub(in crate::application) fn execute_list_categories() -> Result<i32, CliError> {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    for category in IssueCategory::ALL {
        writeln!(out, "{}: {}", category, category.description())
            .map_err(|error| CliErrorKind::session_parse_error(format!("write error: {error}")))?;
    }
    Ok(0)
}

// Focus presets are cfg-gated out of `types` for `standalone-daemon` builds
// (see `types/mod.rs`), so this stays a matching pair of impls rather than a
// single function, the same shape as `scan::filters::apply_focus_filter`.
#[cfg(not(feature = "standalone-daemon"))]
pub(in crate::application) fn execute_list_focus_presets() -> Result<i32, CliError> {
    use crate::types::FOCUS_PRESETS;

    let stdout = io::stdout();
    let mut out = stdout.lock();
    for preset in FOCUS_PRESETS {
        writeln!(out, "{}: {}", preset.name, preset.description)
            .map_err(|error| CliErrorKind::session_parse_error(format!("write error: {error}")))?;
    }
    Ok(0)
}

#[cfg(feature = "standalone-daemon")]
pub(in crate::application) fn execute_list_focus_presets() -> Result<i32, CliError> {
    Err(CliErrorKind::session_parse_error(
        "observe scan --action list-focus-presets is unavailable in a standalone-daemon build",
    )
    .into())
}
