pub(super) mod maintenance;
pub mod session_event;

use crate::errors::{CliError, CliErrorKind};

use super::compare;
use super::doctor;
use super::dump;
use super::scan;
use super::watch;
use super::{ObserveFilterArgs, ObserveMode, ObserveScanActionKind};

enum ObserveScanAction<'a> {
    Scan {
        session_id: &'a str,
        filter: &'a ObserveFilterArgs,
    },
    Cycle {
        session_id: &'a str,
        project_hint: Option<&'a str>,
    },
    Status {
        session_id: &'a str,
        project_hint: Option<&'a str>,
    },
    Resume {
        session_id: &'a str,
        filter: &'a ObserveFilterArgs,
    },
    Verify {
        session_id: &'a str,
        issue_id: &'a str,
        since_line: Option<usize>,
        project_hint: Option<&'a str>,
    },
    ResolveFrom {
        session_id: &'a str,
        value: &'a str,
        project_hint: Option<&'a str>,
    },
    Compare {
        session_id: &'a str,
        from_a: usize,
        to_a: usize,
        from_b: usize,
        to_b: usize,
        project_hint: Option<&'a str>,
    },
    ListCategories,
    ListFocusPresets,
    Doctor,
    Mute {
        session_id: &'a str,
        codes: &'a str,
        project_hint: Option<&'a str>,
    },
    Unmute {
        session_id: &'a str,
        codes: &'a str,
        project_hint: Option<&'a str>,
    },
}

struct ObserveScanRequest<'a> {
    session_id: Option<&'a str>,
    action: Option<ObserveScanActionKind>,
    issue_id: Option<&'a str>,
    since_line: Option<usize>,
    value: Option<&'a str>,
    range_a: Option<&'a str>,
    range_b: Option<&'a str>,
    codes: Option<&'a str>,
    filter: &'a ObserveFilterArgs,
}

struct ObserveDumpRequest {
    session_id: String,
    context_line: Option<usize>,
    context_window: usize,
    from_line: Option<usize>,
    to_line: Option<usize>,
    filter: Option<String>,
    role: Option<String>,
    tool_name: Option<String>,
    raw_json: bool,
    project_hint: Option<String>,
}

pub(crate) fn execute(mode: ObserveMode) -> Result<i32, CliError> {
    match mode {
        ObserveMode::Scan {
            session_id,
            action,
            issue_id,
            since_line,
            value,
            range_a,
            range_b,
            codes,
            filter,
        } => {
            let request = ObserveScanRequest {
                session_id: session_id.as_deref(),
                action,
                issue_id: issue_id.as_deref(),
                since_line,
                value: value.as_deref(),
                range_a: range_a.as_deref(),
                range_b: range_b.as_deref(),
                codes: codes.as_deref(),
                filter: &filter,
            };
            execute_scan_mode(&request)
        }
        ObserveMode::Watch {
            session_id,
            poll_interval,
            timeout,
            filter,
        } => watch::execute_watch(&session_id, poll_interval, timeout, &filter),
        ObserveMode::Dump {
            session_id,
            context_line,
            context_window,
            from_line,
            to_line,
            filter,
            role,
            tool_name,
            raw_json,
            project_hint,
        } => execute_dump_mode(&ObserveDumpRequest {
            session_id,
            context_line,
            context_window,
            from_line,
            to_line,
            filter,
            role,
            tool_name,
            raw_json,
            project_hint,
        }),
    }
}

fn execute_scan_mode(request: &ObserveScanRequest<'_>) -> Result<i32, CliError> {
    match resolve_scan_action(request)? {
        ObserveScanAction::Scan { session_id, filter } => scan::execute_scan(session_id, filter),
        ObserveScanAction::Cycle {
            session_id,
            project_hint,
        } => maintenance::execute_cycle(session_id, project_hint),
        ObserveScanAction::Status {
            session_id,
            project_hint,
        } => maintenance::execute_status(session_id, project_hint),
        ObserveScanAction::Resume { session_id, filter } => {
            maintenance::execute_resume(session_id, filter)
        }
        ObserveScanAction::Verify {
            session_id,
            issue_id,
            since_line,
            project_hint,
        } => maintenance::execute_verify(session_id, issue_id, since_line, project_hint),
        ObserveScanAction::ResolveFrom {
            session_id,
            value,
            project_hint,
        } => maintenance::execute_resolve_start(session_id, value, project_hint),
        ObserveScanAction::Compare {
            session_id,
            from_a,
            to_a,
            from_b,
            to_b,
            project_hint,
        } => compare::execute_compare(session_id, from_a, to_a, from_b, to_b, project_hint),
        ObserveScanAction::ListCategories => maintenance::execute_list_categories(),
        ObserveScanAction::ListFocusPresets => maintenance::execute_list_focus_presets(),
        ObserveScanAction::Doctor => doctor::execute_doctor(),
        ObserveScanAction::Mute {
            session_id,
            codes,
            project_hint,
        } => maintenance::execute_mute(session_id, codes, project_hint),
        ObserveScanAction::Unmute {
            session_id,
            codes,
            project_hint,
        } => maintenance::execute_unmute(session_id, codes, project_hint),
    }
}

fn execute_dump_mode(request: &ObserveDumpRequest) -> Result<i32, CliError> {
    if let Some(line) = request.context_line {
        super::context_cmd::execute_context(
            &request.session_id,
            line,
            request.context_window,
            request.project_hint.as_deref(),
        )
    } else {
        dump::execute_dump(
            &request.session_id,
            &dump::DumpOptions {
                from_line: request.from_line.unwrap_or(0),
                to_line: request.to_line,
                text_filter: request.filter.as_deref(),
                roles: request.role.as_deref(),
                tool_name: request.tool_name.as_deref(),
                raw_json: request.raw_json,
            },
            request.project_hint.as_deref(),
        )
    }
}

fn require_scan_session_id<'a>(
    session_id: Option<&'a str>,
    action: &str,
) -> Result<&'a str, CliError> {
    session_id.ok_or_else(|| {
        CliErrorKind::session_parse_error(format!(
            "observe scan {action} requires a session_id positional argument"
        ))
        .into()
    })
}

fn parse_compare_range(value: &str, label: &str) -> Result<(usize, usize), CliError> {
    let Some((from, to)) = value.split_once(':') else {
        return Err(
            CliErrorKind::session_parse_error(format!("{label} must use FROM:TO syntax")).into(),
        );
    };
    let from = from.parse::<usize>().map_err(|_| {
        CliErrorKind::session_parse_error(format!("{label} has invalid start line '{from}'"))
    })?;
    let to = to.parse::<usize>().map_err(|_| {
        CliErrorKind::session_parse_error(format!("{label} has invalid end line '{to}'"))
    })?;
    Ok((from, to))
}

fn resolve_scan_action<'a>(
    request: &'a ObserveScanRequest<'a>,
) -> Result<ObserveScanAction<'a>, CliError> {
    let project_hint = request.filter.project_hint.as_deref();
    match request.action {
        None => Ok(ObserveScanAction::Scan {
            session_id: require_scan_session_id(request.session_id, "scan")?,
            filter: request.filter,
        }),
        Some(ObserveScanActionKind::Cycle) => Ok(ObserveScanAction::Cycle {
            session_id: require_scan_session_id(request.session_id, "--action cycle")?,
            project_hint,
        }),
        Some(ObserveScanActionKind::Status) => Ok(ObserveScanAction::Status {
            session_id: require_scan_session_id(request.session_id, "--action status")?,
            project_hint,
        }),
        Some(ObserveScanActionKind::Resume) => Ok(ObserveScanAction::Resume {
            session_id: require_scan_session_id(request.session_id, "--action resume")?,
            filter: request.filter,
        }),
        Some(ObserveScanActionKind::Verify) => Ok(ObserveScanAction::Verify {
            session_id: require_scan_session_id(request.session_id, "--action verify")?,
            issue_id: request.issue_id.ok_or_else(|| {
                CliError::from(CliErrorKind::session_parse_error(
                    "--action verify requires --issue-id",
                ))
            })?,
            since_line: request.since_line,
            project_hint,
        }),
        Some(ObserveScanActionKind::ResolveFrom) => Ok(ObserveScanAction::ResolveFrom {
            session_id: require_scan_session_id(request.session_id, "--action resolve-from")?,
            value: request.value.ok_or_else(|| {
                CliError::from(CliErrorKind::session_parse_error(
                    "--action resolve-from requires --value",
                ))
            })?,
            project_hint,
        }),
        Some(ObserveScanActionKind::Compare) => {
            let range_a = request.range_a.ok_or_else(|| {
                CliError::from(CliErrorKind::session_parse_error(
                    "--action compare requires --range-a",
                ))
            })?;
            let range_b = request.range_b.ok_or_else(|| {
                CliError::from(CliErrorKind::session_parse_error(
                    "--action compare requires --range-b",
                ))
            })?;
            let (from_a, to_a) = parse_compare_range(range_a, "--range-a")?;
            let (from_b, to_b) = parse_compare_range(range_b, "--range-b")?;
            Ok(ObserveScanAction::Compare {
                session_id: require_scan_session_id(request.session_id, "--action compare")?,
                from_a,
                to_a,
                from_b,
                to_b,
                project_hint,
            })
        }
        Some(ObserveScanActionKind::ListCategories) => Ok(ObserveScanAction::ListCategories),
        Some(ObserveScanActionKind::ListFocusPresets) => Ok(ObserveScanAction::ListFocusPresets),
        Some(ObserveScanActionKind::Doctor) => Ok(ObserveScanAction::Doctor),
        Some(ObserveScanActionKind::Mute) => Ok(ObserveScanAction::Mute {
            session_id: require_scan_session_id(request.session_id, "--action mute")?,
            codes: request.codes.ok_or_else(|| {
                CliError::from(CliErrorKind::session_parse_error(
                    "--action mute requires --codes",
                ))
            })?,
            project_hint,
        }),
        Some(ObserveScanActionKind::Unmute) => Ok(ObserveScanAction::Unmute {
            session_id: require_scan_session_id(request.session_id, "--action unmute")?,
            codes: request.codes.ok_or_else(|| {
                CliError::from(CliErrorKind::session_parse_error(
                    "--action unmute requires --codes",
                ))
            })?,
            project_hint,
        }),
    }
}
