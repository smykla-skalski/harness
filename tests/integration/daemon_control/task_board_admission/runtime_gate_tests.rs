use super::*;

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
            .is_none_or(std::vec::Vec::is_empty),
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
