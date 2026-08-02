use crate::daemon::agent_acp::{
    AcpAgentSessionState, AcpAgentTurnResult, AcpSessionConfigOptionState, AgentTurnFailure,
    AgentTurnFailureCategory, AgentTurnFailureStage,
};
use crate::daemon::db::AgentTurnRunStatus;

use super::{AgentTurnSettlement, DETACHED_TURN_ERROR};

const AUTHENTICATION_DETAIL: &str = "OpenRouter rejected its credential: HTTP 401 unauthorized";
const MODEL: &str = "deepseek/deepseek-v4-flash";

fn state_with_model() -> AcpAgentSessionState {
    AcpAgentSessionState {
        config_options: vec![AcpSessionConfigOptionState {
            id: super::PROVIDER_EFFECTIVE_MODEL_CONFIG_OPTION_ID.into(),
            name: "Provider effective model".into(),
            category: Some("model".into()),
            current_value: MODEL.into(),
        }],
        ..AcpAgentSessionState::default()
    }
}

#[test]
fn a_running_turn_has_no_terminal_outcome() {
    assert!(AgentTurnSettlement::from_session_state(&state_with_model()).is_none());
}

#[test]
fn a_completed_turn_keeps_its_report_stop_reason_and_effective_model() {
    let mut state = state_with_model();
    state.last_turn_result = Some(AcpAgentTurnResult {
        report: r#"{"summary":"Reviewed.","findings":[]}"#.into(),
        stop_reason: "end_turn".into(),
    });

    let settlement =
        AgentTurnSettlement::from_session_state(&state).expect("completed turn settles");

    assert_eq!(settlement.status, AgentTurnRunStatus::Completed);
    assert_eq!(settlement.actual_model.as_deref(), Some(MODEL));
    assert_eq!(
        settlement.report.as_deref(),
        Some(r#"{"summary":"Reviewed.","findings":[]}"#)
    );
    assert_eq!(settlement.stop_reason.as_deref(), Some("end_turn"));
    assert!(settlement.error.is_none());
}

#[test]
fn a_failed_turn_keeps_the_provider_detail_and_its_partial_output() {
    let mut state = state_with_model();
    state.last_turn_failure = Some(AgentTurnFailure::new(
        AgentTurnFailureCategory::Authentication,
        AgentTurnFailureStage::Execution,
        AUTHENTICATION_DETAIL,
    ));
    state.last_turn_partial_output = Some("partial".into());

    let settlement = AgentTurnSettlement::from_session_state(&state).expect("failed turn settles");

    assert_eq!(settlement.status, AgentTurnRunStatus::Failed);
    assert_eq!(settlement.error.as_deref(), Some(AUTHENTICATION_DETAIL));
    assert_eq!(settlement.report.as_deref(), Some("partial"));
    assert!(settlement.stop_reason.is_none());
}

/// The durable run stores a message, not a category, so the retained detail is
/// the only thing later classification has to work from. The detachment wording
/// carries none of it.
#[test]
fn a_retained_authentication_detail_still_classifies_as_authentication() {
    let mut state = state_with_model();
    state.last_turn_failure = Some(AgentTurnFailure::new(
        AgentTurnFailureCategory::Authentication,
        AgentTurnFailureStage::Execution,
        AUTHENTICATION_DETAIL,
    ));
    let settlement = AgentTurnSettlement::from_session_state(&state).expect("failed turn settles");
    let detail = settlement.error.expect("retained provider detail");

    let category = AgentTurnFailureCategory::from_message(&detail);

    assert_eq!(category, AgentTurnFailureCategory::Authentication);
    assert!(!category.automatic_retry_safe());
    assert_eq!(
        AgentTurnFailureCategory::from_message(DETACHED_TURN_ERROR),
        AgentTurnFailureCategory::Unknown
    );
}

#[test]
fn a_cancelled_turn_settles_as_a_stop_reason_rather_than_an_error() {
    let mut state = state_with_model();
    state.last_turn_failure = Some(AgentTurnFailure::cancelled("agent turn cancelled"));

    let settlement =
        AgentTurnSettlement::from_session_state(&state).expect("cancelled turn settles");

    assert_eq!(settlement.status, AgentTurnRunStatus::Cancelled);
    assert_eq!(
        settlement.stop_reason.as_deref(),
        Some("agent turn cancelled")
    );
    assert!(settlement.error.is_none());
}

/// Starting a turn clears both fields, so this state is unreachable in
/// practice. It is pinned because masking a recorded failure with a result is
/// the one direction that loses a real cause.
#[test]
fn a_failure_outranks_a_result_recorded_on_the_same_state() {
    let mut state = state_with_model();
    state.last_turn_failure = Some(AgentTurnFailure::new(
        AgentTurnFailureCategory::RateLimited,
        AgentTurnFailureStage::Execution,
        "rate limited",
    ));
    state.last_turn_result = Some(AcpAgentTurnResult {
        report: "report".into(),
        stop_reason: "end_turn".into(),
    });

    let settlement = AgentTurnSettlement::from_session_state(&state).expect("turn settles");

    assert_eq!(settlement.status, AgentTurnRunStatus::Failed);
    assert_eq!(settlement.error.as_deref(), Some("rate limited"));
}

#[test]
fn detachment_is_a_failure_with_the_contract_wording() {
    let settlement = AgentTurnSettlement::detached();

    assert_eq!(settlement.status, AgentTurnRunStatus::Failed);
    assert_eq!(settlement.error.as_deref(), Some(DETACHED_TURN_ERROR));
    assert!(settlement.report.is_none());
    assert!(settlement.actual_model.is_none());
}
