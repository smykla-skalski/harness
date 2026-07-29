use std::io::{Read, Write};
use std::net::TcpListener;

use harness::daemon::protocol::DAEMON_WIRE_VERSION;

use super::*;

const SMOKE_MODEL: &str = "deepseek/deepseek-v4-flash";

fn readiness_body(runtime: &str, model: &str) -> Value {
    json!({
        "client_version": "integration-test",
        "client_wire_version": DAEMON_WIRE_VERSION,
        "runtime": runtime,
        "model": model,
    })
}

fn spawn_readiness_daemon(
    home: &Path,
    xdg: &Path,
    openrouter_api_url: Option<&str>,
) -> ManagedChild {
    let mut command = Command::new(daemon_binary());
    configure_daemon_serve_command(&mut command, home, xdg, &[]);
    if let Some(url) = openrouter_api_url {
        command.env("OPENROUTER_API_URL", url);
    }
    ManagedChild::spawn(&mut command).expect("spawn readiness daemon")
}

// A canned OpenRouter stand-in. Each readiness request issues exactly one
// `/models/user` call, so the mock serves a single connection and then the
// thread returns, rather than looping on `incoming()` for the whole suite.
fn spawn_mock_openrouter(status: &'static str, body: &'static str) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock openrouter");
    let address = listener.local_addr().expect("mock openrouter address");
    thread::spawn(move || {
        for stream in listener.incoming().take(1) {
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
    format!("http://{address}")
}

fn store_openrouter_token(endpoint: &str, token: &str, value: &str) {
    let url = format!(
        "{}/v1/task-board/orchestrator/openrouter-token",
        endpoint.trim_end_matches('/')
    );
    let runtime = Runtime::new().expect("runtime");
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    let (status, body) = loop {
        let response = runtime.block_on(async {
            reqwest::Client::new()
                .put(&url)
                .bearer_auth(token)
                .json(&json!({ "token": value }))
                .timeout(DAEMON_HTTP_TIMEOUT)
                .send()
                .await
        });
        match response {
            Ok(response) => {
                let status = response.status().as_u16();
                let body = runtime
                    .block_on(async { response.json::<Value>().await.expect("token json body") });
                break (status, body);
            }
            Err(error) if error.is_connect() || error.is_timeout() => {
                assert!(Instant::now() < deadline, "token sync retry: {error:?}");
                thread::sleep(DAEMON_WAIT_INTERVAL);
            }
            Err(error) => panic!("token sync failed: {error:?}"),
        }
    };
    assert_eq!(status, 200, "token sync failed: {body}");
    assert_eq!(body["token_configured"], json!(true));
}

fn unmet_reasons(report: &Value) -> Vec<String> {
    report["unmet_requirements"]
        .as_array()
        .expect("unmet_requirements array")
        .iter()
        .map(|reason| reason.as_str().expect("reason string").to_owned())
        .collect()
}

#[test]
fn first_readiness_request_after_bridge_reflects_current_bridge_state() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let mut daemon = spawn_readiness_daemon(&home, &xdg, None);
    let _daemon_ready = wait_for_daemon_ready(&home, &xdg);
    let mut bridge = spawn_bridge(&home, &xdg, &["--capability", "acp"]);
    let _bridge_status = wait_for_bridge_capabilities(&home, &xdg, &["acp"]);
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    let (status, report) = post_json(
        &endpoint,
        &token,
        "/v1/headless/readiness",
        readiness_body("openrouter", SMOKE_MODEL),
    );
    assert_eq!(status, 200, "unexpected body: {report}");
    assert_eq!(
        report["bridge_reachable"],
        json!(true),
        "first request must see the now-running bridge, not a stale negative: {report}"
    );
    let acp_lane_available = report["lanes"]
        .as_array()
        .expect("lanes array")
        .iter()
        .find(|lane| lane["name"] == "acp")
        .map(|lane| lane["available"] == json!(true));
    assert_eq!(
        acp_lane_available,
        Some(true),
        "acp lane should be available on the first request: {report}"
    );
    assert_eq!(
        report["ready"].as_bool().expect("ready"),
        unmet_reasons(&report).is_empty(),
        "ready must agree with unmet_requirements: {report}"
    );

    daemon.kill().expect("kill daemon");
    wait_for_child_exit(&mut daemon);
    let _ = run_harness(&home, &xdg, &["bridge", "stop"]);
    wait_for_child_exit(&mut bridge);
}

#[test]
fn rejected_openrouter_credential_blocks_readiness_without_leaking_secret() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let mock = spawn_mock_openrouter("401 Unauthorized", "");
    let mut daemon = spawn_readiness_daemon(&home, &xdg, Some(&mock));
    let _daemon_ready = wait_for_daemon_ready(&home, &xdg);
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);

    let secret = "sk-or-rejected-secret-value";
    store_openrouter_token(&endpoint, &token, secret);

    let (status, report) = post_json(
        &endpoint,
        &token,
        "/v1/headless/readiness",
        readiness_body("openrouter", SMOKE_MODEL),
    );
    assert_eq!(status, 200, "unexpected body: {report}");
    assert_eq!(report["ready"], json!(false));
    assert_eq!(report["credential"]["configured"], json!(false));
    let reasons = unmet_reasons(&report);
    assert!(
        reasons
            .iter()
            .any(|reason| reason.contains("openrouter credential was rejected by the provider")),
        "expected a named rejection reason, got {reasons:?}"
    );
    assert!(
        !report.to_string().contains(secret),
        "report leaked the credential value"
    );

    daemon.kill().expect("kill daemon");
    wait_for_child_exit(&mut daemon);
}

#[test]
fn catalogued_model_absent_from_live_provider_is_rejected() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    // The key is accepted, but the live list omits the requested (catalogued)
    // model, so static catalog membership must not produce a false positive.
    let mock = spawn_mock_openrouter("200 OK", r#"{"data":[{"id":"openai/gpt-5.5"}]}"#);
    let mut daemon = spawn_readiness_daemon(&home, &xdg, Some(&mock));
    let _daemon_ready = wait_for_daemon_ready(&home, &xdg);
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);
    store_openrouter_token(&endpoint, &token, "sk-or-accepted-key");

    let (status, report) = post_json(
        &endpoint,
        &token,
        "/v1/headless/readiness",
        readiness_body("openrouter", SMOKE_MODEL),
    );
    assert_eq!(status, 200, "unexpected body: {report}");
    assert_eq!(report["model"]["available"], json!(false));
    assert_eq!(report["credential"]["configured"], json!(true));
    let reasons = unmet_reasons(&report);
    assert!(
        reasons
            .iter()
            .any(|reason| reason.contains(&format!("model '{SMOKE_MODEL}' is unavailable"))),
        "expected a live model-unavailable reason, got {reasons:?}"
    );
    assert!(
        !reasons.iter().any(|reason| reason.contains("credential")),
        "an accepted credential must not add a credential failure: {reasons:?}"
    );

    daemon.kill().expect("kill daemon");
    wait_for_child_exit(&mut daemon);
}
