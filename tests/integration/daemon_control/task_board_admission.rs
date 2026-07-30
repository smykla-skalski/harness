//! Board-driven admission of imported pull-request tickets, end-to-end against
//! a real spawned daemon.
//!
//! These tests drive the daemon's own HTTP surface: import a pull-request
//! ticket into Inbox, move it straight to Todo, and assert the Todo transition
//! makes it dispatch-ready without a second approval, selects the execution
//! mode its intent requires (a review runs read-only, a dependency update
//! writes), keeps both intents on a combined ticket, and never stamps a
//! duplicate execution across repeated transitions or a refresh.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use super::*;

const REVIEWER_MODEL: &str = "deepseek/deepseek-v4-flash";

// A canned OpenRouter stand-in that serves the same response on every connection
// for the life of the test, so the readiness probe the dispatch gate issues
// reaches a deterministic provider response instead of the real network. Dropping
// the guard stops the worker: it flips the shutdown flag, then opens a throwaway
// connection to wake the parked `accept`, so the thread does not outlive the test.
struct MockOpenRouter {
    url: String,
    address: SocketAddr,
    shutdown: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}

impl MockOpenRouter {
    fn url(&self) -> &str {
        &self.url
    }
}

impl Drop for MockOpenRouter {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        let _ = TcpStream::connect(self.address);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn spawn_persistent_mock_openrouter(status: &'static str, body: &'static str) -> MockOpenRouter {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock openrouter");
    let address = listener.local_addr().expect("mock openrouter address");
    let shutdown = Arc::new(AtomicBool::new(false));
    let worker_shutdown = Arc::clone(&shutdown);
    let worker = thread::spawn(move || {
        for stream in listener.incoming() {
            if worker_shutdown.load(Ordering::SeqCst) {
                break;
            }
            let Ok(mut stream) = stream else { continue };
            let mut request = [0_u8; 4096];
            let _ = stream.read(&mut request);
            let _ = write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
        }
    });
    MockOpenRouter {
        url: format!("http://{address}"),
        address,
        shutdown,
        worker: Some(worker),
    }
}

fn spawn_daemon_with_openrouter_url(
    home: &Path,
    xdg: &Path,
    openrouter_api_url: &str,
) -> ManagedChild {
    let mut command = Command::new(daemon_binary());
    configure_daemon_serve_command(&mut command, home, xdg, &[]);
    command.env("OPENROUTER_API_URL", openrouter_api_url);
    ManagedChild::spawn(&mut command).expect("spawn daemon with openrouter url")
}

fn open_spawn_gate(endpoint: &str, token: &str) {
    let (code, body) = post_json(
        endpoint,
        token,
        "/v1/policy-canvases/spawn-requires-live-policy",
        json!({ "enabled": false }),
    );
    assert_eq!(code, 200, "open spawn gate: {body}");
}

fn select_openrouter_reviewer(endpoint: &str, token: &str) {
    let (code, body) = request_json(
        "PUT",
        endpoint,
        token,
        "/v1/task-board/orchestrator/settings",
        json!({
            "reviewers": {
                "reviewer_count": 1,
                "required_approvals": 1,
                "max_revision_cycles": 3,
                "profiles": [{
                    "id": "openrouter-reviewer",
                    "runtime": "openrouter",
                    "persona": "code-reviewer",
                    "agent_mode": "evaluate",
                    "model": REVIEWER_MODEL,
                }],
            }
        }),
    );
    assert_eq!(code, 200, "select openrouter reviewer: {body}");
}

fn store_openrouter_token(endpoint: &str, token: &str, value: &str) {
    let (code, body) = request_json(
        "PUT",
        endpoint,
        token,
        "/v1/task-board/orchestrator/openrouter-token",
        json!({ "token": value }),
    );
    assert_eq!(code, 200, "store openrouter token: {body}");
    assert_eq!(body["token_configured"], json!(true), "{body}");
}

fn dispatch_review(endpoint: &str, token: &str, id: &str, project: &Path) -> Value {
    let (code, body) = post_json(
        endpoint,
        token,
        "/v1/task-board/dispatch",
        json!({
            "item_id": id,
            "dry_run": false,
            "project_dir": project.to_string_lossy(),
        }),
    );
    assert_eq!(code, 200, "dispatch {id}: {body}");
    body
}

fn create_imported_pull_request(
    endpoint: &str,
    token: &str,
    id: &str,
    workflow_kind: &str,
) -> Value {
    let (status, body) = post_json(
        endpoint,
        token,
        "/v1/task-board/items",
        json!({
            "id": id,
            "title": format!("Imported {workflow_kind}"),
            "status": "inbox",
            "workflow_kind": workflow_kind,
            "execution_repository": "acme/widgets",
            "external_refs": [{
                "provider": "github",
                "external_id": "acme/widgets#17",
                "url": "https://github.com/acme/widgets/pull/17"
            }],
        }),
    );
    assert_eq!(status, 200, "create imported pull request: {body}");
    body
}

fn request_json(
    method: &str,
    endpoint: &str,
    token: &str,
    path: &str,
    body: Value,
) -> (u16, Value) {
    let url = format!(
        "{}/{}",
        endpoint.trim_end_matches('/'),
        path.trim_start_matches('/')
    );
    let token = token.to_string();
    let method = method.to_string();
    let runtime = Runtime::new().expect("runtime");
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let request_body = body.clone();
        let client = reqwest::Client::new();
        let mut builder = match method.as_str() {
            "PUT" => client.put(&url),
            "GET" => client.get(&url),
            other => panic!("unsupported method {other}"),
        }
        .bearer_auth(token.clone())
        .timeout(Duration::from_secs(1));
        // Only methods that carry a payload attach one; a GET body is
        // non-standard and some intermediaries reject it.
        if method != "GET" {
            builder = builder.json(&request_body);
        }
        let response = runtime.block_on(async { builder.send().await });
        match response {
            Ok(response) => {
                let status = response.status().as_u16();
                let json =
                    runtime.block_on(async { response.json::<Value>().await.expect("json body") });
                return (status, json);
            }
            Err(error) if error.is_timeout() || error.is_connect() => {
                assert!(Instant::now() < deadline, "daemon {method}: {error:?}");
                thread::sleep(Duration::from_millis(250));
            }
            Err(error) => panic!("daemon {method}: {error:?}"),
        }
    }
}

fn move_to_status(endpoint: &str, token: &str, id: &str, status: &str) -> Value {
    let (code, body) = request_json(
        "PUT",
        endpoint,
        token,
        &format!("/v1/task-board/items/{id}"),
        json!({ "status": status }),
    );
    assert_eq!(code, 200, "move {id} to {status}: {body}");
    body
}

fn get_item(endpoint: &str, token: &str, id: &str) -> Value {
    let (code, body) = request_json(
        "GET",
        endpoint,
        token,
        &format!("/v1/task-board/items/{id}"),
        Value::Null,
    );
    assert_eq!(code, 200, "get {id}: {body}");
    body
}

fn dispatch_plan(endpoint: &str, token: &str, id: &str) -> Value {
    let (code, body) = post_json(
        endpoint,
        token,
        "/v1/task-board/dispatch",
        json!({ "item_id": id, "dry_run": true }),
    );
    assert_eq!(code, 200, "dispatch dry-run {id}: {body}");
    let plans = body["plans"].as_array().expect("dispatch plans array");
    let matching: Vec<Value> = plans
        .iter()
        .filter(|plan| plan["board_item_id"] == json!(id))
        .cloned()
        .collect();
    assert_eq!(
        matching.len(),
        1,
        "exactly one plan for {id}, got {}: {body}",
        matching.len()
    );
    matching.into_iter().next().expect("matched plan")
}

fn assert_not_blocked_on_approval(plan: &Value) {
    let readiness = &plan["readiness"];
    if readiness["state"] == json!("blocked") {
        assert_ne!(
            readiness["reason"]["kind"],
            json!("plan_approval"),
            "imported pull request must never be stranded on plan approval: {plan}"
        );
    }
}

#[test]
fn moving_an_imported_review_to_todo_admits_it_read_only_without_a_second_approval() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    let _status = wait_for_daemon_ready(&home, &xdg);
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    let created = create_imported_pull_request(&endpoint, &token, "review-pr", "pr_review");
    assert_eq!(created["status"], json!("inbox"));

    let moved = move_to_status(&endpoint, &token, "review-pr", "todo");
    assert_eq!(moved["status"], json!("todo"));
    // The review request selects read-only execution.
    assert_eq!(
        moved["agent_mode"],
        json!("evaluate"),
        "a review must not carry the write-oriented default mode: {moved}"
    );

    let plan = dispatch_plan(&endpoint, &token, "review-pr");
    assert_not_blocked_on_approval(&plan);
    assert_eq!(plan["worker"]["mode"], json!("evaluate"));

    let output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        output.status.success(),
        "stop failed: {}",
        output_text(&output)
    );
    wait_for_child_exit(&mut daemon);
}

#[test]
fn moving_a_dependency_update_to_todo_admits_it_write() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    let _status = wait_for_daemon_ready(&home, &xdg);
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    create_imported_pull_request(&endpoint, &token, "dep-pr", "pr_fix");
    let moved = move_to_status(&endpoint, &token, "dep-pr", "todo");
    // A dependency update selects write execution.
    assert_eq!(moved["agent_mode"], json!("headless"), "{moved}");

    let plan = dispatch_plan(&endpoint, &token, "dep-pr");
    assert_not_blocked_on_approval(&plan);
    assert_eq!(plan["worker"]["mode"], json!("headless"));

    let output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        output.status.success(),
        "stop failed: {}",
        output_text(&output)
    );
    wait_for_child_exit(&mut daemon);
}

#[test]
fn a_combined_ticket_keeps_both_intents_through_admission() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    let _status = wait_for_daemon_ready(&home, &xdg);
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    create_imported_pull_request(&endpoint, &token, "combined-pr", "pr_fix_review");
    let moved = move_to_status(&endpoint, &token, "combined-pr", "todo");
    // The combined ticket keeps both intents and writes.
    assert_eq!(moved["workflow_kind"], json!("pr_fix_review"), "{moved}");
    assert_eq!(moved["agent_mode"], json!("headless"), "{moved}");

    let plan = dispatch_plan(&endpoint, &token, "combined-pr");
    assert_not_blocked_on_approval(&plan);

    let output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        output.status.success(),
        "stop failed: {}",
        output_text(&output)
    );
    wait_for_child_exit(&mut daemon);
}

#[test]
fn a_failed_preparation_does_not_strand_the_ticket_admitting() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    // An existing directory that is not a git repository: the reservation
    // succeeds, then preparation fails when it tries to cut a session worktree.
    let project = tmp.path().join("not-a-git-project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    std::fs::create_dir_all(&project).expect("create project");

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    let _status = wait_for_daemon_ready(&home, &xdg);
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    // Open the fail-closed spawn gate so a spawn is permitted under the built-in
    // policy; without this the dispatch is denied before it ever reserves.
    let (gate_code, gate_body) = post_json(
        &endpoint,
        &token,
        "/v1/policy-canvases/spawn-requires-live-policy",
        json!({ "enabled": false }),
    );
    assert_eq!(gate_code, 200, "open spawn gate: {gate_body}");

    create_imported_pull_request(&endpoint, &token, "stranded-pr", "pr_fix");
    move_to_status(&endpoint, &token, "stranded-pr", "todo");
    let plan = dispatch_plan(&endpoint, &token, "stranded-pr");
    assert_eq!(
        plan["readiness"]["state"],
        json!("ready"),
        "the imported write ticket must be dispatch-ready before we run it: {plan}"
    );

    // A real dispatch reserves the ticket - stamping one Admitting execution -
    // then fails during preparation because the project is not a git repository.
    let (code, body) = post_json(
        &endpoint,
        &token,
        "/v1/task-board/dispatch",
        json!({
            "item_id": "stranded-pr",
            "dry_run": false,
            "project_dir": project.to_string_lossy(),
        }),
    );
    assert_eq!(code, 200, "dispatch stranded-pr: {body}");
    let failures = body["failures"].as_array().expect("failures array");
    assert_eq!(
        failures.len(),
        1,
        "an unusable project must fail preparation: {body}"
    );
    assert_eq!(failures[0]["board_item_id"], json!("stranded-pr"), "{body}");
    assert!(
        body["applied"]
            .as_array()
            .is_none_or(|applied| applied.is_empty()),
        "a failed preparation must not apply the dispatch: {body}"
    );

    // The failed preparation must return the ticket to a clean, retryable state
    // rather than leave it pinned to the dead execution it admitted.
    let item = get_item(&endpoint, &token, "stranded-pr");
    let workflow = &item["workflow"];
    assert_ne!(
        workflow["status"],
        json!("admitting"),
        "a failed preparation must not strand the ticket in Admitting: {item}"
    );
    assert!(
        workflow["execution_id"].is_null(),
        "the dead execution must not remain named as the ticket's owner: {item}"
    );

    let output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        output.status.success(),
        "stop failed: {}",
        output_text(&output)
    );
    wait_for_child_exit(&mut daemon);
}

#[test]
fn repeated_transitions_and_a_refresh_stamp_no_duplicate_execution() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let mut daemon = spawn_daemon_serve(&home, &xdg);
    let _status = wait_for_daemon_ready(&home, &xdg);
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    create_imported_pull_request(&endpoint, &token, "churn-pr", "pr_review");

    // Move to Todo, back to Inbox, and to Todo again. Each transition is a real
    // mutation, and admission must land on the same read-only mode every time.
    move_to_status(&endpoint, &token, "churn-pr", "todo");
    move_to_status(&endpoint, &token, "churn-pr", "inbox");
    let readmitted = move_to_status(&endpoint, &token, "churn-pr", "todo");
    assert_eq!(readmitted["agent_mode"], json!("evaluate"), "{readmitted}");

    // A refresh (repeated dry-run dispatch) plans the same single item and
    // never advances its workflow past idle, so no execution is stamped.
    for _ in 0..3 {
        let plan = dispatch_plan(&endpoint, &token, "churn-pr");
        assert_not_blocked_on_approval(&plan);
    }
    let item = get_item(&endpoint, &token, "churn-pr");
    let workflow_status = item["workflow"]["status"].as_str().unwrap_or("idle");
    assert_eq!(
        workflow_status, "idle",
        "a dry-run refresh must not stamp an execution: {item}"
    );

    let output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        output.status.success(),
        "stop failed: {}",
        output_text(&output)
    );
    wait_for_child_exit(&mut daemon);
}

#[test]
fn an_unavailable_reviewer_runtime_fails_the_review_before_agent_work_and_stays_retryable() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo(&project);

    // The provider rejects the configured credential, so the supported openrouter
    // runtime is configured but cannot run.
    let mock = spawn_persistent_mock_openrouter("401 Unauthorized", "");
    let mut daemon = spawn_daemon_with_openrouter_url(&home, &xdg, mock.url());
    let _status = wait_for_daemon_ready(&home, &xdg);
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    open_spawn_gate(&endpoint, &token);
    select_openrouter_reviewer(&endpoint, &token);
    let secret = "sk-or-rejected-launch-secret-value";
    store_openrouter_token(&endpoint, &token, secret);

    create_imported_pull_request(&endpoint, &token, "review-blocked", "pr_review");
    move_to_status(&endpoint, &token, "review-blocked", "todo");

    let body = dispatch_review(&endpoint, &token, "review-blocked", &project);
    let failures = body["failures"].as_array().expect("failures array");
    assert_eq!(
        failures.len(),
        1,
        "an unavailable reviewer runtime must fail the dispatch: {body}"
    );
    let message = failures[0]["message"].as_str().expect("failure message");
    assert!(
        message.contains("reviewer runtime 'openrouter' cannot run"),
        "the block must name the runtime that cannot run: {message}"
    );
    assert!(
        message.contains("credential was rejected by the provider"),
        "the block must name the specific unmet prerequisite: {message}"
    );
    assert!(
        !body.to_string().contains(secret),
        "the dispatch response leaked the credential value: {body}"
    );
    assert!(
        body["applied"]
            .as_array()
            .is_none_or(|applied| applied.is_empty()),
        "a runtime that cannot run must not apply the dispatch: {body}"
    );

    // The block is retryable, not a permanent human-required stop: the ticket
    // returns to a clean state that a later dispatch can pick up once the
    // prerequisite is met.
    let item = get_item(&endpoint, &token, "review-blocked");
    let workflow = &item["workflow"];
    assert_ne!(
        workflow["status"],
        json!("admitting"),
        "an unavailable runtime must not strand the ticket in Admitting: {item}"
    );
    assert!(
        workflow["execution_id"].is_null(),
        "a blocked launch must not pin the ticket to a dead execution: {item}"
    );

    let output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        output.status.success(),
        "stop failed: {}",
        output_text(&output)
    );
    wait_for_child_exit(&mut daemon);
}

#[test]
fn a_satisfied_reviewer_runtime_prerequisite_lets_the_dispatch_pass_the_readiness_gate() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");
    init_git_repo(&project);

    // The provider accepts the credential and offers the requested model, so the
    // readiness prerequisite is met.
    let mock = spawn_persistent_mock_openrouter(
        "200 OK",
        r#"{"data":[{"id":"deepseek/deepseek-v4-flash"}]}"#,
    );
    let mut daemon = spawn_daemon_with_openrouter_url(&home, &xdg, mock.url());
    let _status = wait_for_daemon_ready(&home, &xdg);
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    open_spawn_gate(&endpoint, &token);
    select_openrouter_reviewer(&endpoint, &token);
    store_openrouter_token(&endpoint, &token, "sk-or-accepted-launch-key");

    create_imported_pull_request(&endpoint, &token, "review-ready", "pr_review");
    move_to_status(&endpoint, &token, "review-ready", "todo");

    // With the prerequisite met, the readiness gate no longer blocks. The dispatch
    // moves past it to exact-head resolution; in this offline test that later step
    // is what fails, never the reviewer-runtime gate.
    let body = dispatch_review(&endpoint, &token, "review-ready", &project);
    let gate_blocked = body["failures"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|failure| failure["message"].as_str())
        .any(|message| message.contains("cannot run"));
    assert!(
        !gate_blocked,
        "a met prerequisite must let the dispatch pass the readiness gate: {body}"
    );

    let output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        output.status.success(),
        "stop failed: {}",
        output_text(&output)
    );
    wait_for_child_exit(&mut daemon);
}
