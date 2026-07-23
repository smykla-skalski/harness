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

use harness::daemon::http::openapi::openapi_json_value;
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
    ("GET", "/v1/projects"),
    ("GET", "/v1/runtime-sessions/resolve"),
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
        let found = HTTP_API_CONTRACT
            .iter()
            .any(|route| route.method.as_str() == *method && route.path == *path);
        assert!(
            found,
            "documented route {method} {path} is absent from HTTP_API_CONTRACT \
             (did a #[utoipa::path] literal drift from http_paths?)"
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
