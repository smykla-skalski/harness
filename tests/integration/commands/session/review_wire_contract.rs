//! End-to-end protocol parity for the v10 review workflow routes.
//!
//! Asserts each new route appears in the daemon's public API contract table
//! with the exact method, path, websocket mapping, and Swift-exposure flag,
//! plus that every new request type round-trips through `serde_json`. This
//! keeps the HTTP client, the websocket dispatch, and the Swift Monitor on
//! the same contract without requiring a live daemon process in the
//! integration suite.

use harness::daemon::protocol::{
    HTTP_API_CONTRACT, HttpApiRouteContract, HttpRouteMethod, HttpRouteParity,
    ImproverApplyRequest, TaskArbitrateRequest, TaskClaimReviewRequest, TaskRespondReviewRequest,
    TaskSubmitForReviewRequest, TaskSubmitReviewRequest, http_paths, ws_methods,
};
use harness::session::service::ImproverTarget;
use harness::session::types::{ReviewPoint, ReviewPointState, ReviewVerdict};

fn contract_for(path: &str) -> &'static HttpApiRouteContract {
    HTTP_API_CONTRACT
        .iter()
        .find(|route| route.path == path)
        .unwrap_or_else(|| panic!("route {path} missing from HTTP_API_CONTRACT"))
}

fn assert_review_rpc_contract(
    path: &'static str,
    expected_method: HttpRouteMethod,
    expected_ws_method: &'static str,
) {
    let route = contract_for(path);
    assert_eq!(
        route.method, expected_method,
        "{path} should be registered as {expected_method:?}"
    );
    assert!(
        route.swift_client_exposed,
        "{path} must be exposed to the Swift monitor"
    );
    match route.parity {
        HttpRouteParity::Rpc { ws_method } => {
            assert_eq!(
                ws_method, expected_ws_method,
                "{path} should map to websocket method {expected_ws_method}"
            );
        }
        HttpRouteParity::Exempt { .. } => {
            panic!("{path} must be Rpc-parity, not exempt")
        }
    }
}

#[test]
fn submit_for_review_route_is_on_contract() {
    assert_eq!(
        http_paths::SESSION_TASK_SUBMIT_FOR_REVIEW,
        "/v1/sessions/{session_id}/tasks/{task_id}/submit-for-review"
    );
    assert_review_rpc_contract(
        http_paths::SESSION_TASK_SUBMIT_FOR_REVIEW,
        HttpRouteMethod::Post,
        ws_methods::TASK_SUBMIT_FOR_REVIEW,
    );
}

#[test]
fn claim_review_route_is_on_contract() {
    assert_eq!(
        http_paths::SESSION_TASK_CLAIM_REVIEW,
        "/v1/sessions/{session_id}/tasks/{task_id}/claim-review"
    );
    assert_review_rpc_contract(
        http_paths::SESSION_TASK_CLAIM_REVIEW,
        HttpRouteMethod::Post,
        ws_methods::TASK_CLAIM_REVIEW,
    );
}

#[test]
fn submit_review_route_is_on_contract() {
    assert_eq!(
        http_paths::SESSION_TASK_SUBMIT_REVIEW,
        "/v1/sessions/{session_id}/tasks/{task_id}/submit-review"
    );
    assert_review_rpc_contract(
        http_paths::SESSION_TASK_SUBMIT_REVIEW,
        HttpRouteMethod::Post,
        ws_methods::TASK_SUBMIT_REVIEW,
    );
}

#[test]
fn respond_review_route_is_on_contract() {
    assert_eq!(
        http_paths::SESSION_TASK_RESPOND_REVIEW,
        "/v1/sessions/{session_id}/tasks/{task_id}/respond-review"
    );
    assert_review_rpc_contract(
        http_paths::SESSION_TASK_RESPOND_REVIEW,
        HttpRouteMethod::Post,
        ws_methods::TASK_RESPOND_REVIEW,
    );
}

#[test]
fn arbitrate_route_is_on_contract() {
    assert_eq!(
        http_paths::SESSION_TASK_ARBITRATE,
        "/v1/sessions/{session_id}/tasks/{task_id}/arbitrate"
    );
    assert_review_rpc_contract(
        http_paths::SESSION_TASK_ARBITRATE,
        HttpRouteMethod::Post,
        ws_methods::TASK_ARBITRATE,
    );
}

#[test]
fn improver_apply_route_is_on_contract() {
    assert_eq!(
        http_paths::SESSION_IMPROVER_APPLY,
        "/v1/sessions/{session_id}/improver/apply"
    );
    assert_review_rpc_contract(
        http_paths::SESSION_IMPROVER_APPLY,
        HttpRouteMethod::Post,
        ws_methods::IMPROVER_APPLY,
    );
}

#[test]
fn submit_for_review_request_round_trips() {
    let original = TaskSubmitForReviewRequest {
        actor: "worker-1".into(),
        summary: Some("ready".into()),
        suggested_persona: Some("code-reviewer".into()),
    };
    let json = serde_json::to_string(&original).expect("serialize");
    let decoded: TaskSubmitForReviewRequest = serde_json::from_str(&json).expect("decode");
    assert_eq!(decoded.actor, "worker-1");
    assert_eq!(decoded.summary.as_deref(), Some("ready"));
    assert_eq!(decoded.suggested_persona.as_deref(), Some("code-reviewer"));
}

#[test]
fn claim_review_request_round_trips() {
    let original = TaskClaimReviewRequest {
        actor: "rev-1".into(),
    };
    let json = serde_json::to_string(&original).expect("serialize");
    let decoded: TaskClaimReviewRequest = serde_json::from_str(&json).expect("decode");
    assert_eq!(decoded.actor, "rev-1");
}

#[test]
fn submit_review_request_round_trips_with_points() {
    let original = TaskSubmitReviewRequest {
        actor: "rev-1".into(),
        verdict: ReviewVerdict::RequestChanges,
        summary: "needs rework".into(),
        points: vec![ReviewPoint {
            point_id: "p1".into(),
            text: "fix this".into(),
            state: ReviewPointState::Open,
            worker_note: None,
        }],
    };
    let json = serde_json::to_string(&original).expect("serialize");
    assert!(
        json.contains("\"verdict\":\"request_changes\""),
        "expected snake_case verdict in {json}"
    );
    let decoded: TaskSubmitReviewRequest = serde_json::from_str(&json).expect("decode");
    assert_eq!(decoded.verdict, ReviewVerdict::RequestChanges);
    assert_eq!(decoded.points.len(), 1);
    assert_eq!(decoded.points[0].point_id, "p1");
}

#[test]
fn submit_review_request_accepts_legacy_kebab_verdict() {
    let legacy = r#"{
        "actor": "rev-1",
        "verdict": "request-changes",
        "summary": "legacy client",
        "points": []
    }"#;
    let decoded: TaskSubmitReviewRequest =
        serde_json::from_str(legacy).expect("accept legacy kebab verdict");
    assert_eq!(decoded.verdict, ReviewVerdict::RequestChanges);
}

#[test]
fn respond_review_request_round_trips() {
    let original = TaskRespondReviewRequest {
        actor: "worker-1".into(),
        agreed: vec!["p1".into()],
        disputed: vec!["p2".into(), "p3".into()],
        note: Some("partial agreement".into()),
    };
    let json = serde_json::to_string(&original).expect("serialize");
    let decoded: TaskRespondReviewRequest = serde_json::from_str(&json).expect("decode");
    assert_eq!(decoded.agreed, vec!["p1"]);
    assert_eq!(decoded.disputed, vec!["p2", "p3"]);
    assert_eq!(decoded.note.as_deref(), Some("partial agreement"));
}

#[test]
fn arbitrate_request_round_trips() {
    let original = TaskArbitrateRequest {
        actor: "leader".into(),
        verdict: ReviewVerdict::Approve,
        summary: "shipping".into(),
    };
    let json = serde_json::to_string(&original).expect("serialize");
    let decoded: TaskArbitrateRequest = serde_json::from_str(&json).expect("decode");
    assert_eq!(decoded.verdict, ReviewVerdict::Approve);
    assert_eq!(decoded.summary, "shipping");
}

#[test]
fn improver_apply_request_round_trips_with_target_enum() {
    let original = ImproverApplyRequest {
        actor: "improver".into(),
        issue_id: "issue-1".into(),
        target: ImproverTarget::Skill,
        rel_path: "demo/SKILL.md".into(),
        new_contents: "hello".into(),
        project_dir: "/repo".into(),
        dry_run: false,
    };
    let json = serde_json::to_string(&original).expect("serialize");
    assert!(
        json.contains("\"target\":\"skill\""),
        "expected snake_case target in {json}"
    );
    let decoded: ImproverApplyRequest = serde_json::from_str(&json).expect("decode");
    assert!(matches!(decoded.target, ImproverTarget::Skill));
    assert!(!decoded.dry_run);
}
