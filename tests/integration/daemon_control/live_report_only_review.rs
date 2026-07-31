use std::time::{Duration, Instant};

use reqwest::Method;
use serde_json::{Value, json};

use super::*;

#[path = "live_report_only_review/support.rs"]
mod support;

use support::{
    GitHubClient, GitHubSnapshot, LiveReviewTarget, LocalRepositorySnapshot,
    prepare_review_checkout,
};

const OPENROUTER_MODEL: &str = "deepseek/deepseek-v4-flash";
const REVIEW_TIMEOUT: Duration = Duration::from_mins(6);

fn required_env(name: &str, runtime: &str, model: &str) -> String {
    std::env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| {
            panic!(
                "stage=credential runtime={runtime} requested_model={model}: {name} is missing or empty"
            )
        })
}

struct DaemonClient {
    runtime: Runtime,
    client: reqwest::Client,
    endpoint: String,
    token: String,
}

impl DaemonClient {
    fn new(endpoint: &str, token: &str) -> Self {
        Self {
            runtime: Runtime::new().expect("stage=http_client: create runtime"),
            client: reqwest::Client::new(),
            endpoint: endpoint.trim_end_matches('/').to_owned(),
            token: token.to_owned(),
        }
    }

    fn request(&self, method: Method, path: &str, body: Option<&Value>) -> Value {
        let url = format!("{}{path}", self.endpoint);
        self.runtime.block_on(async {
            let mut request = self
                .client
                .request(method, url)
                .bearer_auth(&self.token)
                .timeout(Duration::from_secs(30));
            if let Some(body) = body {
                request = request.json(body);
            }
            let response = request.send().await.expect("stage=http: send request");
            let status = response.status();
            let text = response.text().await.expect("stage=http: read response");
            assert!(status.is_success(), "stage=http: HTTP {status}: {text}");
            serde_json::from_str(&text).expect("stage=http: decode response")
        })
    }
}

#[test]
#[ignore = "explicit live validation; reviews a real GitHub PR with OpenRouter"]
fn requested_review_reaches_a_durable_report_without_mutation() {
    let openrouter_token = required_env("OPENROUTER_API_KEY", "openrouter", OPENROUTER_MODEL);
    let github_token = required_env("HARNESS_LIVE_GITHUB_TOKEN", "github", "read-only");
    let github = GitHubClient::new(&github_token);
    let target = LiveReviewTarget::from_env(&github);
    let before = GitHubSnapshot::capture(&target, &github);
    let tmp = tempdir().expect("stage=fixture: create tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("stage=fixture: create home");
    std::fs::create_dir_all(&xdg).expect("stage=fixture: create xdg");
    prepare_review_checkout(&target, &project, &github_token);
    let initial_repository = LocalRepositorySnapshot::capture(&project);

    let mut daemon = spawn_daemon_serve_with_args(&home, &xdg, &["--sandboxed"]);
    let _daemon_ready = wait_for_daemon_ready(&home, &xdg);
    let mut bridge = spawn_bridge(&home, &xdg, &["--capability", "acp"]);
    let _bridge_ready = wait_for_bridge_capabilities(&home, &xdg, &["acp"]);
    let (endpoint, daemon_token) = current_daemon_endpoint_and_token(&home, &xdg);
    let http = DaemonClient::new(&endpoint, &daemon_token);
    configure_runtime(&http, &openrouter_token, &github_token);
    let item_id = create_and_dispatch(&http, &target, &project);
    let report = poll_terminal_report(&http, &item_id);

    assert_completed_report(&report, &target);
    assert_eq!(
        LocalRepositorySnapshot::capture(&project),
        initial_repository
    );
    let after = GitHubSnapshot::capture(&target, &github);
    assert_eq!(after, before, "report-only review mutated GitHub state");

    stop_bridge(&home, &xdg, &mut bridge);
    daemon.kill().expect("stage=restart: stop first daemon");
    wait_for_child_exit(&mut daemon);
    let mut restarted = spawn_daemon_serve_with_args(&home, &xdg, &["--sandboxed"]);
    let _restarted_ready = wait_for_daemon_ready(&home, &xdg);
    let (endpoint, daemon_token) = current_daemon_endpoint_and_token(&home, &xdg);
    let restarted_http = DaemonClient::new(&endpoint, &daemon_token);
    let retained = restarted_http.request(
        Method::GET,
        &format!("/v1/task-board/items/{item_id}/review-report"),
        None,
    );
    assert_eq!(retained, report, "restart changed the durable report");
    assert_eq!(
        LocalRepositorySnapshot::capture(&project),
        initial_repository
    );
    let final_snapshot = GitHubSnapshot::capture(&target, &github);
    assert_eq!(
        final_snapshot, before,
        "restart reconciliation mutated GitHub"
    );

    println!(
        "{}",
        serde_json::to_string_pretty(&report).expect("stage=output: encode report")
    );
    restarted
        .kill()
        .expect("stage=cleanup: stop restarted daemon");
    wait_for_child_exit(&mut restarted);
}

fn configure_runtime(http: &DaemonClient, openrouter_token: &str, github_token: &str) {
    http.request(
        Method::POST,
        "/v1/policy-canvases/spawn-requires-live-policy",
        Some(&json!({ "enabled": false })),
    );
    let openrouter = http.request(
        Method::PUT,
        "/v1/task-board/orchestrator/openrouter-token",
        Some(&json!({ "token": openrouter_token })),
    );
    assert_eq!(openrouter["token_configured"], true);
    let github = http.request(
        Method::PUT,
        "/v1/task-board/orchestrator/github-tokens",
        Some(&json!({ "global_token": github_token })),
    );
    assert_eq!(github["global_token_configured"], true);
}

fn create_and_dispatch(http: &DaemonClient, target: &LiveReviewTarget, project: &Path) -> String {
    let item_id = format!("live-review-pr-{}", target.number);
    let created = http.request(
        Method::POST,
        "/v1/task-board/items",
        Some(&json!({
            "id": item_id,
            "title": format!("Live report-only review of PR #{}", target.number),
            "body": "Review the exact pull request revision and return only the report contract.",
            "status": "inbox",
            "workflow_kind": "pr_review",
            "execution_repository": target.repository,
            "external_refs": [{
                "provider": "github",
                "external_id": format!("{}#{}", target.repository, target.number),
                "url": target.url
            }]
        })),
    );
    assert_eq!(created["status"], "inbox");
    let moved = http.request(
        Method::PUT,
        &format!("/v1/task-board/items/{item_id}"),
        Some(&json!({ "status": "todo" })),
    );
    assert_eq!(moved["status"], "todo");
    assert_eq!(moved["agent_mode"], "evaluate");
    let dispatch = http.request(
        Method::POST,
        "/v1/task-board/dispatch",
        Some(&json!({
            "item_id": item_id,
            "dry_run": false,
            "project_dir": project
        })),
    );
    assert!(
        dispatch["failures"]
            .as_array()
            .is_none_or(std::vec::Vec::is_empty),
        "stage=dispatch: {dispatch}"
    );
    assert_eq!(
        dispatch["applied"].as_array().map(Vec::len),
        Some(1),
        "stage=dispatch: {dispatch}"
    );
    item_id
}

fn poll_terminal_report(http: &DaemonClient, item_id: &str) -> Value {
    let deadline = Instant::now() + REVIEW_TIMEOUT;
    let path = format!("/v1/task-board/items/{item_id}/review-report");
    loop {
        let report = http.request(Method::GET, &path, None);
        match report["status"].as_str() {
            Some("completed") => return report,
            Some("failed" | "cancelled") => {
                panic!("stage=review: terminal failure: {report}")
            }
            Some("not_started" | "running") => {}
            status => panic!("stage=review: unknown report status {status:?}: {report}"),
        }
        assert!(
            Instant::now() < deadline,
            "stage=review: timed out waiting for {path}; last={report}"
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

fn assert_completed_report(report: &Value, target: &LiveReviewTarget) {
    let retained = &report["report"];
    assert_eq!(report["status"], "completed");
    assert_eq!(retained["repository"], target.repository);
    assert_eq!(retained["pull_request_number"], target.number);
    assert_eq!(retained["head_revision"], target.head);
    assert_eq!(retained["runtime"], "openrouter");
    assert_eq!(retained["requested_runtime"], "openrouter");
    assert_eq!(retained["actual_runtime"], "openrouter");
    assert_eq!(retained["requested_model"], OPENROUTER_MODEL);
    assert_eq!(retained["effective_model"], OPENROUTER_MODEL);
    assert!(
        retained["summary"]
            .as_str()
            .is_some_and(|summary| !summary.trim().is_empty()),
        "completed report has no summary: {report}"
    );
}

fn stop_bridge(home: &Path, xdg: &Path, bridge: &mut ManagedChild) {
    let output = run_harness(home, xdg, &["bridge", "stop"]);
    assert!(
        output.status.success(),
        "stage=cleanup: bridge stop failed: {}",
        output_text(&output)
    );
    wait_for_child_exit(bridge);
}
