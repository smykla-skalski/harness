use std::path::Path;

use serde::Serialize;

use crate::errors::CliError;

use super::super::application::ObserveFilter;
use super::super::types::Issue;
use super::filters::apply_filters;
use super::from::{resolve_effective_bounds, resolve_effective_from_line};
use super::io::{scan_with_limit, write_details_file};
use super::render::render_scan_output;
use crate::observe::session;

#[derive(Serialize)]
struct ScanStarted<'a> {
    status: &'static str,
    session: &'a str,
    from_line: usize,
}

/// One-shot scan returning all classified issues.
pub(crate) fn scan(path: &Path, from_line: usize) -> Result<(Vec<Issue>, usize), CliError> {
    scan_with_limit(path, from_line, None)
}

/// Execute scan mode.
pub(crate) fn execute_scan(session_id: &str, filter: &ObserveFilter) -> Result<i32, CliError> {
    let path = session::find_session(session_id, filter.project_hint.as_deref())?;
    let from_line = resolve_effective_from_line(filter, &path)?;

    if filter.json {
        let session = path.to_string_lossy();
        println!(
            "{}",
            serde_json::to_string(&ScanStarted {
                status: "started",
                session: session.as_ref(),
                from_line,
            })
            .expect("scan status serializes")
        );
    }

    let (effective_from, effective_until) = resolve_effective_bounds(&path, filter, from_line)?;

    let (issues, last_line) = scan_with_limit(&path, effective_from, effective_until)?;
    let filtered = apply_filters(issues, filter)?;

    if let Some(ref details_path) = filter.output_details {
        write_details_file(details_path, &filtered)?;
    }

    render_scan_output(filter, &filtered, last_line);

    Ok(0)
}
