//! Keeps the generated OpenAPI document honest against the authoritative HTTP
//! route contract.
//!
//! `DOCUMENTED_ROUTES` lists the `(method, path)` pairs whose handlers carry
//! `#[utoipa::path]` today. It GROWS as each PR-series slice annotates another
//! route domain; when it covers every non-exempt contract route the coverage
//! check is fully closed. The checks fail loudly if a handler is annotated
//! without updating this list (or vice versa), if a documented path literal
//! drifts from `http_paths`, or if an operation's `x-websocket-method`
//! extension disagrees with the route contract's parity.

use std::collections::BTreeSet;

use axum::http::Method;
use harness::daemon::http::openapi::{execution_operation, openapi_json_value};
use harness::daemon::protocol::HTTP_API_CONTRACT;

const HTTP_METHODS: [&str; 4] = ["get", "post", "put", "delete"];

/// `(METHOD, path)` pairs whose handlers are annotated with `#[utoipa::path]`.
/// Extend this as each slice annotates a route domain; the final slice makes it
/// cover every non-exempt route in `HTTP_API_CONTRACT` plus the remote-execution
/// transport.
const DOCUMENTED_ROUTES: &[(&str, &str)] = &[
    ("GET", "/v1/health"),
    ("GET", "/v1/ready"),
    ("POST", "/v1/daemon/stop"),
    ("GET", "/v1/daemon/log-level"),
    ("PUT", "/v1/daemon/log-level"),
    ("POST", "/v1/daemon/telemetry"),
    ("GET", "/v1/github/status"),
    ("GET", "/v1/projects"),
    ("GET", "/v1/runtime-sessions/resolve"),
    ("GET", "/v1/sessions"),
    ("POST", "/v1/sessions"),
    ("POST", "/v1/sessions/adopt"),
    ("GET", "/v1/sessions/{session_id}"),
    ("DELETE", "/v1/sessions/{session_id}"),
    ("GET", "/v1/sessions/{session_id}/timeline"),
    ("POST", "/v1/sessions/{session_id}/join"),
    ("POST", "/v1/sessions/{session_id}/runtime-session"),
    ("POST", "/v1/sessions/{session_id}/title"),
    ("POST", "/v1/sessions/{session_id}/end"),
    ("POST", "/v1/sessions/{session_id}/archive"),
    ("POST", "/v1/sessions/{session_id}/leave"),
    ("POST", "/v1/sessions/{session_id}/observe"),
    ("POST", "/v1/sessions/{session_id}/task"),
    ("POST", "/v1/sessions/{session_id}/tasks/{task_id}"),
    ("POST", "/v1/sessions/{session_id}/tasks/{task_id}/assign"),
    ("POST", "/v1/sessions/{session_id}/tasks/{task_id}/drop"),
    ("POST", "/v1/sessions/{session_id}/tasks/{task_id}/queue-policy"),
    ("POST", "/v1/sessions/{session_id}/tasks/{task_id}/status"),
    ("POST", "/v1/sessions/{session_id}/tasks/{task_id}/checkpoint"),
    ("POST", "/v1/sessions/{session_id}/tasks/{task_id}/submit-for-review"),
    ("POST", "/v1/sessions/{session_id}/tasks/{task_id}/claim-review"),
    ("POST", "/v1/sessions/{session_id}/tasks/{task_id}/submit-review"),
    ("POST", "/v1/sessions/{session_id}/tasks/{task_id}/respond-review"),
    ("POST", "/v1/sessions/{session_id}/tasks/{task_id}/arbitrate"),
    ("POST", "/v1/sessions/{session_id}/agents/{session_agent_id}/role"),
    ("POST", "/v1/sessions/{session_id}/agents/{session_agent_id}/remove"),
    ("POST", "/v1/sessions/{session_id}/leader"),
    ("POST", "/v1/sessions/{session_id}/improver/apply"),
    ("GET", "/v1/sessions/{session_id}/managed-agents"),
    ("POST", "/v1/sessions/{session_id}/managed-agents/terminal"),
    ("POST", "/v1/sessions/{session_id}/managed-agents/codex"),
    ("POST", "/v1/sessions/{session_id}/managed-agents/acp"),
    ("GET", "/v1/managed-agents/{managed_agent_id}"),
    ("DELETE", "/v1/managed-agents/{managed_agent_id}"),
    ("POST", "/v1/managed-agents/{managed_agent_id}/input"),
    ("POST", "/v1/managed-agents/{managed_agent_id}/resize"),
    ("POST", "/v1/managed-agents/{managed_agent_id}/stop"),
    ("POST", "/v1/managed-agents/{managed_agent_id}/ready"),
    ("POST", "/v1/managed-agents/{managed_agent_id}/steer"),
    ("POST", "/v1/managed-agents/{managed_agent_id}/interrupt"),
    ("POST", "/v1/managed-agents/{managed_agent_id}/approvals/{approval_id}"),
    ("POST", "/v1/managed-agents/{managed_agent_id}/permission-batches/{batch_id}"),
    ("POST", "/v1/managed-agents/{managed_agent_id}/prompt"),
    ("POST", "/v1/managed-agents/{managed_agent_id}/logout"),
    ("GET", "/v1/managed-agents/{managed_agent_id}/sessions"),
    ("DELETE", "/v1/managed-agents/{managed_agent_id}/sessions/{agent_session_id}"),
    ("POST", "/v1/managed-agents/{managed_agent_id}/sessions/{agent_session_id}/close"),
    ("GET", "/v1/managed-agents/codex/inspect"),
    ("GET", "/v1/managed-agents/codex/transcript"),
    ("GET", "/v1/managed-agents/acp/inspect"),
    ("GET", "/v1/managed-agents/acp/transcript"),
    ("POST", "/v1/reviews/repositories"),
    ("GET", "/v1/reviews/capabilities"),
    ("POST", "/v1/reviews/query"),
    ("POST", "/v1/reviews/pull-requests/resolve"),
    ("POST", "/v1/reviews/action-preview"),
    ("POST", "/v1/reviews/policy/preview"),
    ("POST", "/v1/reviews/policy/start"),
    ("POST", "/v1/reviews/policy/status"),
    ("POST", "/v1/reviews/policy/history"),
    ("POST", "/v1/reviews/approve"),
    ("POST", "/v1/reviews/merge"),
    ("POST", "/v1/reviews/rerun-checks"),
    ("POST", "/v1/reviews/labels"),
    ("POST", "/v1/reviews/auto"),
    ("POST", "/v1/reviews/request-review"),
    ("DELETE", "/v1/reviews/cache"),
    ("POST", "/v1/reviews/refresh"),
    ("POST", "/v1/reviews/body"),
    ("POST", "/v1/reviews/body/update"),
    ("POST", "/v1/reviews/comment"),
    ("POST", "/v1/reviews/files/list"),
    ("POST", "/v1/reviews/files/comment"),
    ("POST", "/v1/reviews/files/patch"),
    ("POST", "/v1/reviews/files/preview"),
    ("POST", "/v1/reviews/files/viewed"),
    ("POST", "/v1/reviews/files/blob"),
    ("POST", "/v1/reviews/files/local-clones"),
    ("POST", "/v1/reviews/files/local-clones/delete"),
    ("POST", "/v1/reviews/avatar"),
    ("POST", "/v1/reviews/timeline"),
    ("POST", "/v1/reviews/review-threads/resolve"),
    ("GET", "/v1/task-board/capabilities"),
    ("POST", "/v1/task-board/items"),
    ("GET", "/v1/task-board/items"),
    ("GET", "/v1/task-board/items/{item_id}"),
    ("PUT", "/v1/task-board/items/{item_id}"),
    ("DELETE", "/v1/task-board/items/{item_id}"),
    ("POST", "/v1/task-board/items/{item_id}/planning/begin"),
    ("POST", "/v1/task-board/items/{item_id}/planning/submit"),
    ("POST", "/v1/task-board/items/{item_id}/planning/approve"),
    ("POST", "/v1/task-board/items/{item_id}/planning/revoke"),
    ("POST", "/v1/task-board/sync"),
    ("POST", "/v1/task-board/dispatch"),
    ("POST", "/v1/task-board/dispatch/deliver"),
    ("POST", "/v1/task-board/dispatch/pick"),
    ("POST", "/v1/task-board/evaluate"),
    ("GET", "/v1/task-board/audit"),
    ("GET", "/v1/task-board/projects"),
    ("GET", "/v1/task-board/machines"),
    ("GET", "/v1/task-board/host/local"),
    ("GET", "/v1/task-board/host/list"),
    ("PUT", "/v1/task-board/host/project-types"),
    ("GET", "/v1/task-board/items/{item_id}/position"),
    ("PUT", "/v1/task-board/items/{item_id}/position"),
    ("POST", "/v1/task-board/items/{item_id}/position/reset"),
    ("GET", "/v1/task-board/items/{item_id}/triage"),
    ("GET", "/v1/task-board/items/{item_id}/triage/history"),
    ("PUT", "/v1/task-board/items/{item_id}/triage/override"),
    ("POST", "/v1/task-board/items/{item_id}/triage/override/clear"),
    ("GET", "/v1/task-board/triage/rules/draft"),
    ("PUT", "/v1/task-board/triage/rules/draft"),
    ("POST", "/v1/task-board/triage/rules/preview"),
    ("POST", "/v1/task-board/triage/rules/activate"),
    ("GET", "/v1/task-board/triage/rules/revisions"),
    ("GET", "/v1/task-board/triage/rules/audit"),
    ("GET", "/v1/task-board/orchestrator/status"),
    ("POST", "/v1/task-board/orchestrator/start"),
    ("POST", "/v1/task-board/orchestrator/stop"),
    ("POST", "/v1/task-board/orchestrator/run-once"),
    ("GET", "/v1/task-board/orchestrator/runs"),
    ("GET", "/v1/task-board/orchestrator/runs/{run_id}"),
    ("GET", "/v1/task-board/orchestrator/metrics"),
    ("POST", "/v1/task-board/orchestrator/force-cancel"),
    ("GET", "/v1/task-board/orchestrator/settings"),
    ("PUT", "/v1/task-board/orchestrator/settings"),
    ("GET", "/v1/task-board/orchestrator/runtime-config"),
    ("PUT", "/v1/task-board/orchestrator/runtime-config"),
    ("PUT", "/v1/task-board/orchestrator/github-tokens"),
    ("PUT", "/v1/task-board/orchestrator/todoist-token"),
    ("PUT", "/v1/task-board/orchestrator/openrouter-token"),
    ("GET", "/v1/task-board/git/identity-defaults"),
    ("POST", "/v1/task-board/git/signing/verify"),
    ("PUT", "/v1/task-board/git/runtime/key-material"),
    ("POST", "/v1/task-board/git/runtime/secret-handoff/prepare"),
    ("POST", "/v1/task-board/git/runtime/secret-handoff/ack"),
    ("GET", "/v1/policy-canvases"),
    ("POST", "/v1/policy-canvases/create"),
    ("POST", "/v1/policy-canvases/duplicate"),
    ("POST", "/v1/policy-canvases/rename"),
    ("POST", "/v1/policy-canvases/active"),
    ("POST", "/v1/policy-canvases/delete"),
    ("POST", "/v1/policy-canvases/global-enforcement"),
    ("POST", "/v1/policy-canvases/spawn-requires-live-policy"),
    ("POST", "/v1/policy-canvases/spawn-kill-switch"),
    ("POST", "/v1/policy-canvases/export"),
    ("POST", "/v1/policy-canvases/import"),
    ("GET", "/v1/policy-approval-grants"),
    ("POST", "/v1/policy-approval-grants/resolve"),
    ("POST", "/v1/policy-approval-grants/revoke"),
    ("GET", "/v1/policy-pipeline"),
    ("PUT", "/v1/policy-pipeline"),
    ("POST", "/v1/policy-pipeline/simulate"),
    ("POST", "/v1/policy-pipeline/promote"),
    ("POST", "/v1/policy-pipeline/make-live"),
    ("POST", "/v1/policy-pipeline/go-live-diff"),
    ("POST", "/v1/policy-pipeline/replay"),
    ("GET", "/v1/policy-pipeline/audit"),
    ("POST", "/v1/policy-scenarios/create"),
    ("POST", "/v1/policy-scenarios/update"),
    ("POST", "/v1/policy-scenarios/delete"),
    ("POST", "/v1/policy-scenarios/reset"),
    ("POST", "/v1/policies/dump"),
    ("POST", "/v1/policies/import"),
    // Remote-execution transport: documented but outside HTTP_API_CONTRACT;
    // recognised by task_board_remote_transport::execution_operation.
    ("GET", "/v1/task-board-execution/advertise"),
    ("POST", "/v1/task-board-execution/offers"),
    ("POST", "/v1/task-board-execution/source-bundles/upload"),
    ("POST", "/v1/task-board-execution/source-bundles/receipt"),
    ("POST", "/v1/task-board-execution/source-bundles/abandon"),
    ("POST", "/v1/task-board-execution/claims"),
    ("POST", "/v1/task-board-execution/leases/renew"),
    ("POST", "/v1/task-board-execution/status"),
    ("POST", "/v1/task-board-execution/cancel"),
    ("POST", "/v1/task-board-execution/settled"),
    ("POST", "/v1/task-board-execution/artifacts/fetch"),
    ("POST", "/v1/task-board-execution/cleanup/observe"),
];

fn documented_operations() -> BTreeSet<(String, String)> {
    let doc = openapi_json_value();
    let paths = doc
        .get("paths")
        .and_then(serde_json::Value::as_object)
        .expect("generated document has a paths object");
    let mut operations = BTreeSet::new();
    for (path, item) in paths {
        let item = item.as_object().expect("path item is an object");
        for method in HTTP_METHODS {
            if item.contains_key(method) {
                operations.insert((method.to_uppercase(), path.clone()));
            }
        }
    }
    operations
}

fn contract_ws_method(method: &str, path: &str) -> Option<&'static str> {
    HTTP_API_CONTRACT
        .iter()
        .find(|route| route.method.as_str().eq_ignore_ascii_case(method) && route.path == path)
        .and_then(|route| route.parity.ws_method())
}

#[test]
fn documented_operations_match_annotation_allowlist() {
    let present = documented_operations();
    let expected: BTreeSet<(String, String)> = DOCUMENTED_ROUTES
        .iter()
        .map(|(method, path)| ((*method).to_owned(), (*path).to_owned()))
        .collect();
    assert_eq!(
        present, expected,
        "generated OpenAPI operations must match DOCUMENTED_ROUTES exactly; annotate the \
         handler and add its (method, path) here, or drop the stale entry"
    );
}

#[test]
fn documented_routes_exist_in_contract() {
    for (method, path) in DOCUMENTED_ROUTES {
        let in_contract = HTTP_API_CONTRACT
            .iter()
            .any(|route| route.method.as_str() == *method && route.path == *path);
        let in_transport = Method::from_bytes(method.as_bytes())
            .ok()
            .is_some_and(|method| execution_operation(&method, path).is_some());
        assert!(
            in_contract || in_transport,
            "documented route {method} {path} is absent from both HTTP_API_CONTRACT and the \
             remote-execution transport (did a #[utoipa::path] literal drift from http_paths \
             or execution_operation?)"
        );
    }
}

#[test]
fn websocket_extension_matches_contract_parity() {
    let doc = openapi_json_value();
    let paths = doc
        .get("paths")
        .and_then(serde_json::Value::as_object)
        .expect("generated document has a paths object");
    for (path, item) in paths {
        let item = item.as_object().expect("path item is an object");
        for method in HTTP_METHODS {
            let Some(operation) = item.get(method).and_then(serde_json::Value::as_object) else {
                continue;
            };
            let extension = operation
                .get("x-websocket-method")
                .and_then(serde_json::Value::as_str);
            let expected = contract_ws_method(method, path);
            assert_eq!(
                extension,
                expected,
                "{} {path}: x-websocket-method must match the route contract parity",
                method.to_uppercase()
            );
        }
    }
}

#[test]
fn every_operation_documents_cross_cutting_responses() {
    // (status, shared component, present only when the operation has a body).
    const CROSS_CUTTING: &[(&str, &str, bool)] = &[
        ("401", "RemoteAuthRequired", false),
        ("414", "RemoteRequestUriTooLong", false),
        ("429", "RemoteRequestThrottled", false),
        ("431", "RemoteRequestHeadersTooLarge", false),
        ("503", "RemoteServiceUnavailable", false),
        ("504", "RemoteRequestTimedOut", false),
        ("413", "RemoteRequestBodyTooLarge", true),
    ];

    let doc = openapi_json_value();
    let shared = doc
        .pointer("/components/responses")
        .and_then(serde_json::Value::as_object)
        .expect("components/responses is defined once");
    for (_status, component, _body_only) in CROSS_CUTTING {
        assert!(
            shared.contains_key(*component),
            "shared response {component} must be defined"
        );
    }

    let paths = doc
        .get("paths")
        .and_then(serde_json::Value::as_object)
        .expect("generated document has a paths object");
    for (path, item) in paths {
        let item = item.as_object().expect("path item is an object");
        for method in HTTP_METHODS {
            let Some(operation) = item.get(method).and_then(serde_json::Value::as_object) else {
                continue;
            };
            let has_body = operation.contains_key("requestBody");
            let responses = operation
                .get("responses")
                .and_then(serde_json::Value::as_object)
                .unwrap_or_else(|| panic!("{method} {path} has no responses"));
            for (status, component, body_only) in CROSS_CUTTING {
                let reference = responses
                    .get(*status)
                    .and_then(|response| response.get("$ref"))
                    .and_then(serde_json::Value::as_str);
                if *body_only && !has_body {
                    assert!(
                        reference.is_none(),
                        "{method} {path} should not document {status} without a request body"
                    );
                    continue;
                }
                let expected = format!("#/components/responses/{component}");
                assert_eq!(
                    reference,
                    Some(expected.as_str()),
                    "{method} {path} status {status} must reference the {component} response"
                );
            }
        }
    }
}

#[test]
fn docs_describe_openapi_generation_workflow() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let agents = super::super::helpers::read_repo_file(root, "AGENTS.md");
    let readme = super::super::helpers::read_repo_file(root, "README.md");
    let mise = super::super::helpers::read_repo_file(root, ".mise.toml");
    super::super::helpers::assert_docs_contain_needles(
        &[agents.as_str(), readme.as_str(), mise.as_str()],
        "OpenAPI workflow docs should mention",
        &[
            "mise run openapi:generate",
            "mise run openapi:check",
            "docs/api/openapi.json",
        ],
    );
}
