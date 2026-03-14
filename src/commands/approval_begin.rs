use crate::core_defs::utc_now;
use crate::errors::CliError;
use crate::workflow::author::{
    ApprovalMode, AuthorDraftState, AuthorPhase, AuthorReviewState, AuthorSessionInfo,
    AuthorWorkflowState, write_author_state,
};

/// Begin suite-author approval flow.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(mode: &str, suite_dir: Option<&str>) -> Result<i32, CliError> {
    let approval_mode = match mode {
        "interactive" => ApprovalMode::Interactive,
        "bypass" => ApprovalMode::Bypass,
        _ => {
            return Err(CliError {
                code: "USAGE".to_string(),
                message: format!("invalid approval mode: {mode}"),
                exit_code: 1,
                hint: None,
                details: None,
            });
        }
    };

    let initial_phase = if approval_mode == ApprovalMode::Bypass {
        AuthorPhase::Writing
    } else {
        AuthorPhase::Discovery
    };

    let state = AuthorWorkflowState {
        schema_version: 1,
        mode: approval_mode,
        phase: initial_phase,
        session: AuthorSessionInfo {
            repo_root: None,
            feature: None,
            suite_name: None,
            suite_dir: suite_dir.map(String::from),
        },
        review: AuthorReviewState {
            gate: None,
            awaiting_answer: false,
            round: 0,
            last_answer: None,
        },
        draft: AuthorDraftState {
            suite_tree_written: false,
            written_paths: vec![],
        },
        updated_at: utc_now(),
        transition_count: 0,
        last_event: Some("ApprovalFlowStarted".to_string()),
    };

    write_author_state(&state)?;
    Ok(0)
}
