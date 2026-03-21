use std::path::Path;

use serde_json::json;

use super::*;

fn make_state(phase: AuthorPhase, mode: ApprovalMode) -> AuthorWorkflowState {
    AuthorWorkflowState {
        mode,
        phase,
        session: AuthorSessionInfo {
            repo_root: None,
            feature: None,
            suite_name: None,
            suite_dir: Some("/tmp/suite".to_string()),
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
        updated_at: "2025-01-01T00:00:00Z".to_string(),
        transition_count: 0,
        last_event: None,
    }
}

#[test]
fn author_phase_display() {
    let cases = [
        (AuthorPhase::Discovery, "discovery"),
        (AuthorPhase::PrewriteReview, "prewrite_review"),
        (AuthorPhase::Writing, "writing"),
        (AuthorPhase::PostwriteReview, "postwrite_review"),
        (AuthorPhase::Complete, "complete"),
        (AuthorPhase::Cancelled, "cancelled"),
    ];
    for (variant, expected) in cases {
        assert_eq!(variant.to_string(), expected);
    }
}

#[test]
fn approval_mode_serialization() {
    let json = serde_json::to_value(ApprovalMode::Interactive).unwrap();
    assert_eq!(json, "interactive");
    let json = serde_json::to_value(ApprovalMode::Bypass).unwrap();
    assert_eq!(json, "bypass");
}

#[test]
fn author_phase_serialization() {
    let cases = [
        (AuthorPhase::Discovery, "discovery"),
        (AuthorPhase::PrewriteReview, "prewrite_review"),
        (AuthorPhase::Writing, "writing"),
        (AuthorPhase::PostwriteReview, "postwrite_review"),
        (AuthorPhase::Complete, "complete"),
        (AuthorPhase::Cancelled, "cancelled"),
    ];
    for (variant, expected) in cases {
        let json = serde_json::to_value(variant).unwrap();
        assert_eq!(json, expected);
    }
}

#[test]
fn review_gate_serialization() {
    for (variant, expected) in [
        (ReviewGate::Prewrite, "prewrite"),
        (ReviewGate::Postwrite, "postwrite"),
        (ReviewGate::Copy, "copy"),
    ] {
        let json = serde_json::to_value(variant).unwrap();
        assert_eq!(json, expected);
    }
}

#[test]
fn author_answer_serialization() {
    let cases = [
        (AuthorAnswer::ApproveProposal, "Approve proposal"),
        (AuthorAnswer::RequestChanges, "Request changes"),
        (AuthorAnswer::Cancel, "Cancel"),
        (AuthorAnswer::ApproveSuite, "Approve suite"),
        (AuthorAnswer::CopyCommand, "Copy command"),
        (AuthorAnswer::Skip, "Skip"),
    ];
    for (variant, expected) in cases {
        let json = serde_json::to_value(variant).unwrap();
        assert_eq!(json, expected);
    }
}

#[test]
fn full_state_serialization_round_trip() {
    let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
    let json = serde_json::to_value(&state).unwrap();
    assert!(json.get("schema_version").is_none());
    assert_eq!(json["state"]["phase"], "writing");
    let loaded: AuthorWorkflowState = serde_json::from_value(json).unwrap();
    assert_eq!(loaded, state);
}

#[test]
fn can_write_bypass_always_allows() {
    let state = make_state(AuthorPhase::Discovery, ApprovalMode::Bypass);
    assert!(can_write(&state).is_ok());
}

#[test]
fn can_write_writing_phase_allows() {
    let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
    assert!(can_write(&state).is_ok());
}

#[test]
fn can_write_discovery_denies() {
    let state = make_state(AuthorPhase::Discovery, ApprovalMode::Interactive);
    assert!(can_write(&state).is_err());
}

#[test]
fn can_write_prewrite_review_denies() {
    let state = make_state(AuthorPhase::PrewriteReview, ApprovalMode::Interactive);
    assert!(can_write(&state).unwrap_err().contains("pre-write"));
}

#[test]
fn can_write_postwrite_review_denies() {
    let state = make_state(AuthorPhase::PostwriteReview, ApprovalMode::Interactive);
    assert!(can_write(&state).unwrap_err().contains("post-write"));
}

#[test]
fn can_write_complete_denies() {
    let state = make_state(AuthorPhase::Complete, ApprovalMode::Interactive);
    assert!(can_write(&state).unwrap_err().contains("approved"));
}

#[test]
fn can_write_cancelled_denies() {
    let state = make_state(AuthorPhase::Cancelled, ApprovalMode::Interactive);
    assert!(can_write(&state).unwrap_err().contains("cancelled"));
}

#[test]
fn can_request_gate_bypass_denies() {
    let state = make_state(AuthorPhase::Writing, ApprovalMode::Bypass);
    assert!(
        can_request_gate(&state, ReviewGate::Postwrite)
            .unwrap_err()
            .contains("bypass")
    );
}

#[test]
fn can_request_prewrite_gate_in_prewrite_review() {
    let state = make_state(AuthorPhase::PrewriteReview, ApprovalMode::Interactive);
    assert!(can_request_gate(&state, ReviewGate::Prewrite).is_ok());
}

#[test]
fn can_request_prewrite_gate_wrong_phase() {
    let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
    assert!(can_request_gate(&state, ReviewGate::Prewrite).is_err());
}

#[test]
fn can_request_postwrite_gate_after_writing() {
    let mut state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
    state.draft.suite_tree_written = true;
    assert!(can_request_gate(&state, ReviewGate::Postwrite).is_ok());
}

#[test]
fn can_request_postwrite_gate_without_writes_denies() {
    let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
    assert!(can_request_gate(&state, ReviewGate::Postwrite).is_err());
}

#[test]
fn can_request_copy_gate_in_complete() {
    let state = make_state(AuthorPhase::Complete, ApprovalMode::Interactive);
    assert!(can_request_gate(&state, ReviewGate::Copy).is_ok());
}

#[test]
fn can_request_copy_gate_wrong_phase() {
    let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
    assert!(can_request_gate(&state, ReviewGate::Copy).is_err());
}

#[test]
fn can_stop_bypass_allows() {
    let state = make_state(AuthorPhase::Writing, ApprovalMode::Bypass);
    assert!(can_stop(&state).is_ok());
}

#[test]
fn can_stop_cancelled_allows() {
    let state = make_state(AuthorPhase::Cancelled, ApprovalMode::Interactive);
    assert!(can_stop(&state).is_ok());
}

#[test]
fn can_stop_writing_denies() {
    let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
    assert!(can_stop(&state).unwrap_err().contains("post-write"));
}

#[test]
fn can_stop_postwrite_review_denies() {
    let state = make_state(AuthorPhase::PostwriteReview, ApprovalMode::Interactive);
    assert!(can_stop(&state).unwrap_err().contains("post-write"));
}

#[test]
fn next_action_none() {
    assert_eq!(next_action(None), AuthorNextAction::ReloadState);
    assert!(next_action(None).to_string().contains("Reload"));
}

#[test]
fn next_action_bypass() {
    let state = make_state(AuthorPhase::Discovery, ApprovalMode::Bypass);
    assert_eq!(next_action(Some(&state)), AuthorNextAction::ContinueBypass);
    assert!(next_action(Some(&state)).to_string().contains("bypass"));
}

#[test]
fn next_action_each_phase() {
    let phases = [
        (AuthorPhase::Discovery, "discovery"),
        (AuthorPhase::PrewriteReview, "pre-write"),
        (AuthorPhase::PostwriteReview, "post-write"),
        (AuthorPhase::Cancelled, "cancelled"),
        (AuthorPhase::Complete, "approved"),
    ];
    for (phase, expected_substr) in phases {
        let state = make_state(phase, ApprovalMode::Interactive);
        let action = next_action(Some(&state));
        assert!(
            action.to_string().to_lowercase().contains(expected_substr),
            "phase {phase:?} action should contain '{expected_substr}': {action}"
        );
    }
}

#[test]
fn next_action_writing_with_suite_written() {
    let mut state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
    state.draft.suite_tree_written = true;
    assert_eq!(next_action(Some(&state)), AuthorNextAction::ApplyEditRound);
    assert!(next_action(Some(&state)).to_string().contains("edit round"));
}

#[test]
fn next_action_writing_without_suite_written() {
    let state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
    assert_eq!(
        next_action(Some(&state)),
        AuthorNextAction::ContinueInitialWrite
    );
    assert!(next_action(Some(&state)).to_string().contains("initial"));
}

#[test]
fn suite_author_path_allowed_suite_md() {
    let suite = Path::new("/tmp/suite");
    assert!(suite_author_path_allowed(&suite.join("suite.md"), suite));
}

#[test]
fn suite_author_path_allowed_groups() {
    let suite = Path::new("/tmp/suite");
    assert!(suite_author_path_allowed(
        &suite.join("groups").join("g1.md"),
        suite
    ));
}

#[test]
fn suite_author_path_allowed_baseline() {
    let suite = Path::new("/tmp/suite");
    assert!(suite_author_path_allowed(
        &suite.join("baseline").join("b1.yaml"),
        suite
    ));
}

#[test]
fn suite_author_path_denied_outside() {
    let suite = Path::new("/tmp/suite");
    assert!(!suite_author_path_allowed(
        Path::new("/tmp/other/file.md"),
        suite
    ));
}

#[test]
fn suite_author_path_denied_random_file_in_suite() {
    let suite = Path::new("/tmp/suite");
    assert!(!suite_author_path_allowed(&suite.join("random.txt"), suite));
}

#[test]
fn has_written_suite_delegates_to_draft() {
    let mut state = make_state(AuthorPhase::Writing, ApprovalMode::Interactive);
    assert!(!state.has_written_suite());
    state.draft.suite_tree_written = true;
    assert!(state.has_written_suite());
}

#[test]
fn session_info_suite_path() {
    let info = AuthorSessionInfo {
        repo_root: None,
        feature: None,
        suite_name: None,
        suite_dir: Some("/tmp/suite".to_string()),
    };
    assert_eq!(info.suite_path(), Some(PathBuf::from("/tmp/suite")));

    let info_none = AuthorSessionInfo {
        repo_root: None,
        feature: None,
        suite_name: None,
        suite_dir: None,
    };
    assert_eq!(info_none.suite_path(), None);
}

#[test]
fn deserialize_rejects_legacy_flat_shape() {
    let legacy = json!({
        "mode": "interactive",
        "phase": "discovery",
        "session": {
            "suite_dir": "/tmp/suite"
        },
        "review": {
            "awaiting_answer": false,
            "round": 0
        },
        "draft": {
            "suite_tree_written": false,
            "written_paths": []
        },
        "updated_at": "2025-01-01T00:00:00Z",
        "transition_count": 0,
        "last_event": "ApprovalFlowStarted"
    });

    let error = serde_json::from_value::<AuthorWorkflowState>(legacy).unwrap_err();
    assert!(error.to_string().contains("state"));
}
