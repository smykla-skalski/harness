use crate::errors::CliError;
use crate::observe::application::maintenance::{load_observer_state, save_observer_state};
use crate::observe::types::IssueCode;

pub(in crate::observe::application) fn execute_mute(
    session_id: &str,
    codes: &str,
    _project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let mut state = load_observer_state(session_id)?;
    extend_muted_codes(&mut state.muted_codes, codes);
    save_observer_state(session_id, &state)?;
    println!("Muted codes: {}", render_muted_codes(&state.muted_codes));
    Ok(0)
}

pub(in crate::observe::application) fn execute_unmute(
    session_id: &str,
    codes: &str,
    _project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let mut state = load_observer_state(session_id)?;
    for code_str in codes.split(',') {
        if let Some(code) = IssueCode::from_label(code_str.trim()) {
            state.muted_codes.retain(|muted| *muted != code);
        }
    }
    save_observer_state(session_id, &state)?;
    println!("Muted codes: {}", render_muted_codes(&state.muted_codes));
    Ok(0)
}

fn extend_muted_codes(muted_codes: &mut Vec<IssueCode>, codes: &str) {
    for code in parse_issue_codes(codes) {
        if !muted_codes.contains(&code) {
            muted_codes.push(code);
        }
    }
}

fn parse_issue_codes(codes: &str) -> Vec<IssueCode> {
    codes.split(',').filter_map(parse_issue_code).collect()
}

fn parse_issue_code(code_str: &str) -> Option<IssueCode> {
    IssueCode::from_label(code_str.trim())
}

fn render_muted_codes(muted_codes: &[IssueCode]) -> String {
    muted_codes
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(", ")
}
