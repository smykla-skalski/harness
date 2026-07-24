//! Keeps the generated OpenAPI document honest against the authoritative HTTP
//! route contract.
//!
//! The daemon HTTP API is fully documented: every non-exempt route in
//! `HTTP_API_CONTRACT`, plus the remote-execution transport, carries a
//! `#[utoipa::path]` annotation. `documented_operations_match_contract` derives
//! the expected operation set from the contract (minus `OPENAPI_EXEMPT`) and the
//! transport table and asserts the generated document matches it exactly, so a
//! new handler that ships without a schema entry - or a documented path literal
//! that drifts - fails loudly. The remaining checks keep the `x-websocket-method`
//! extension and the cross-cutting responses in sync.

use std::collections::BTreeSet;

use harness::daemon::http::openapi::{EXECUTION_OPERATIONS, openapi_json_value};
use harness::daemon::protocol::HTTP_API_CONTRACT;

const HTTP_METHODS: [&str; 4] = ["get", "post", "put", "delete"];

/// Routes served over plain HTTP that cannot be represented as an OpenAPI
/// request/response operation: WebSocket upgrades and server-sent event streams
/// carry no JSON body schema, so they are intentionally absent from the
/// generated document. Every other non-exempt contract route must be documented.
const OPENAPI_EXEMPT: &[(&str, &str, &str)] = &[
    (
        "GET",
        "/v1/ws",
        "websocket upgrade transport, not a request/response operation",
    ),
    (
        "GET",
        "/v1/stream",
        "server-sent global event stream, not a request/response operation",
    ),
    (
        "GET",
        "/v1/sessions/{session_id}/stream",
        "server-sent session event stream, not a request/response operation",
    ),
    (
        "GET",
        "/v1/managed-agents/{managed_agent_id}/attach",
        "raw terminal attach stream, not a request/response operation",
    ),
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

/// The operations the generated document must contain: every non-exempt route
/// in `HTTP_API_CONTRACT` plus the remote-execution transport (which sits
/// outside the contract by design).
fn expected_operations() -> BTreeSet<(String, String)> {
    let exempt: BTreeSet<(String, String)> = OPENAPI_EXEMPT
        .iter()
        .map(|(method, path, _)| ((*method).to_owned(), (*path).to_owned()))
        .collect();
    let mut expected = BTreeSet::new();
    for route in HTTP_API_CONTRACT.iter() {
        let key = (route.method.as_str().to_uppercase(), route.path.to_owned());
        if !exempt.contains(&key) {
            expected.insert(key);
        }
    }
    for (method, path, _) in EXECUTION_OPERATIONS {
        expected.insert((method.as_str().to_uppercase(), (*path).to_owned()));
    }
    expected
}

fn contract_ws_method(method: &str, path: &str) -> Option<&'static str> {
    HTTP_API_CONTRACT
        .iter()
        .find(|route| route.method.as_str().eq_ignore_ascii_case(method) && route.path == path)
        .and_then(|route| route.parity.ws_method())
}

#[test]
fn documented_operations_match_contract() {
    let present = documented_operations();
    let expected = expected_operations();
    assert_eq!(
        present, expected,
        "generated OpenAPI operations must exactly match every non-exempt HTTP_API_CONTRACT route \
         plus the remote-execution transport; annotate the missing handler, drop the stale \
         annotation, or add an intentional OPENAPI_EXEMPT entry with a reason"
    );
}

#[test]
fn openapi_exemptions_are_stable() {
    assert_eq!(OPENAPI_EXEMPT.len(), 4, "unexpected OpenAPI exemption count");
    let documented = documented_operations();
    let contract: BTreeSet<(String, String)> = HTTP_API_CONTRACT
        .iter()
        .map(|route| (route.method.as_str().to_uppercase(), route.path.to_owned()))
        .collect();
    for (method, path, reason) in OPENAPI_EXEMPT {
        let key = ((*method).to_owned(), (*path).to_owned());
        assert!(
            contract.contains(&key),
            "OpenAPI-exempt route {method} {path} must exist in HTTP_API_CONTRACT"
        );
        assert!(
            !documented.contains(&key),
            "OpenAPI-exempt route {method} {path} must not be documented; remove the exemption or \
             the annotation"
        );
        assert!(
            !reason.trim().is_empty(),
            "OpenAPI-exempt route {method} {path} needs a non-empty reason"
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
