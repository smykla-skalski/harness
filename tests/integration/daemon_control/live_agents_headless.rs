use std::time::Duration;

use reqwest::Method;
use serde::Serialize;

use super::*;

mod permissions;
mod transcript;

const OPENROUTER_MODEL: &str = "deepseek/deepseek-v4-flash";
const CODEX_MODEL: &str = "gpt-5.3-codex-spark";
const SMOKE_TIMEOUT: Duration = Duration::from_secs(180);
const SMOKE_PROMPT: &str =
    "Return one short plain-text sentence confirming this headless report turn completed.";

#[derive(Debug, Serialize)]
struct LiveAgentSmokeReport {
    correlation_id: String,
    runtime: String,
    requested_model: String,
    effective_model: Option<String>,
    terminal_status: String,
    report: Option<String>,
    failure_stage: Option<String>,
    error: Option<String>,
}

#[derive(Debug)]
struct SmokeFailure {
    correlation_id: String,
    runtime: &'static str,
    requested_model: &'static str,
    stage: &'static str,
    error: String,
}

struct DaemonHttpClient {
    runtime: Runtime,
    client: reqwest::Client,
    endpoint: String,
    token: String,
}

impl DaemonHttpClient {
    fn new(endpoint: &str, token: &str) -> Self {
        Self {
            runtime: Runtime::new().expect("stage=http_client: create runtime"),
            client: reqwest::Client::new(),
            endpoint: endpoint.trim_end_matches('/').to_owned(),
            token: token.to_owned(),
        }
    }

    fn request_json(
        &self,
        method: Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, String> {
        let url = format!("{}{path}", self.endpoint);
        self.runtime.block_on(async {
            let mut request = self
                .client
                .request(method, &url)
                .bearer_auth(&self.token)
                .timeout(Duration::from_secs(10));
            if let Some(body) = body {
                request = request.json(&body);
            }
            let response = request.send().await.map_err(|error| error.to_string())?;
            let status = response.status();
            let text = response.text().await.map_err(|error| error.to_string())?;
            if !status.is_success() {
                return Err(format!("HTTP {status}: {text}"));
            }
            serde_json::from_str(&text).map_err(|error| format!("decode HTTP response: {error}"))
        })
    }
}

impl SmokeFailure {
    fn new(
        correlation_id: impl Into<String>,
        runtime: &'static str,
        requested_model: &'static str,
        stage: &'static str,
        error: impl Into<String>,
    ) -> Self {
        Self {
            correlation_id: correlation_id.into(),
            runtime,
            requested_model,
            stage,
            error: error.into(),
        }
    }

    fn into_report(self) -> LiveAgentSmokeReport {
        LiveAgentSmokeReport {
            correlation_id: self.correlation_id,
            runtime: self.runtime.to_owned(),
            requested_model: self.requested_model.to_owned(),
            effective_model: None,
            terminal_status: "failed".to_owned(),
            report: None,
            failure_stage: Some(self.stage.to_owned()),
            error: Some(self.error),
        }
    }
}

#[test]
#[ignore = "explicit live validation; requires OpenRouter and Codex credentials"]
fn openrouter_and_codex_complete_without_monitor() {
    assert_live_models_are_catalog_cheapest();
    let openrouter_token = required_env("OPENROUTER_API_KEY", "openrouter", OPENROUTER_MODEL);
    let codex_path = required_env("HARNESS_LIVE_CODEX_PATH", "codex", CODEX_MODEL);
    let tmp = tempdir().expect("stage=fixture: create tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&home).expect("stage=fixture: create home");
    std::fs::create_dir_all(&xdg).expect("stage=fixture: create xdg");
    init_git_repo(&project);

    let mut daemon = spawn_daemon_serve_with_args(&home, &xdg, &["--sandboxed"]);
    let _daemon_ready = wait_for_daemon_ready(&home, &xdg);
    let codex_port = TcpPortLease::acquire().expect("stage=bridge_start: reserve Codex port");
    let port_text = codex_port.port().to_string();
    let mut bridge = spawn_bridge_with_port_lease(
        &home,
        &xdg,
        &[
            "--capability",
            "codex",
            "--capability",
            "acp",
            "--codex-port",
            &port_text,
            "--codex-path",
            &codex_path,
        ],
        codex_port,
    );
    let _bridge_ready = wait_for_bridge_capabilities(&home, &xdg, &["codex", "acp"]);
    let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);
    let http = DaemonHttpClient::new(&endpoint, &token);

    let openrouter = run_openrouter(&home, &xdg, &project, &http, &openrouter_token)
        .unwrap_or_else(SmokeFailure::into_report);
    let codex = run_codex(&home, &xdg, &project, &http).unwrap_or_else(SmokeFailure::into_report);
    let reports = vec![openrouter, codex];
    println!(
        "{}",
        serde_json::to_string_pretty(&reports).expect("stage=output: serialize smoke reports")
    );

    let bridge_stop = run_harness(&home, &xdg, &["bridge", "stop"]);
    assert!(
        bridge_stop.status.success(),
        "stage=cleanup: bridge stop failed: {}",
        output_text(&bridge_stop)
    );
    wait_for_child_exit(&mut bridge);
    daemon.kill().expect("stage=cleanup: kill daemon");
    wait_for_child_exit(&mut daemon);

    assert!(
        reports.iter().all(|report| report.failure_stage.is_none()),
        "one or more live agent reports failed"
    );
}

fn assert_live_models_are_catalog_cheapest() {
    for (runtime, expected) in [("openrouter", OPENROUTER_MODEL), ("codex", CODEX_MODEL)] {
        let catalog = harness::agents::runtime::models::catalog_for(runtime)
            .expect("live runtime model catalog");
        assert_eq!(catalog.cheapest_fastest, expected);
    }
}

fn run_openrouter(
    home: &Path,
    xdg: &Path,
    project: &Path,
    http: &DaemonHttpClient,
    openrouter_token: &str,
) -> Result<LiveAgentSmokeReport, SmokeFailure> {
    let runtime = "openrouter";
    http.request_json(
        Method::PUT,
        "/v1/task-board/orchestrator/openrouter-token",
        Some(json!({ "token": openrouter_token })),
    )
    .map_err(|error| {
        SmokeFailure::new(
            "not-started",
            runtime,
            OPENROUTER_MODEL,
            "credential_sync",
            error,
        )
    })?;
    let project_arg = project.to_str().expect("UTF-8 project");
    let session = start_session_via_http(
        home,
        xdg,
        project_arg,
        "headless-live-openrouter",
        "OpenRouter headless live smoke",
        SMOKE_PROMPT,
    );
    let correlation_id = session.session_id.clone();
    let start_path = format!("/v1/sessions/{correlation_id}/managed-agents/acp");
    let started = http
        .request_json(
            Method::POST,
            &start_path,
            Some(json!({
                "descriptor_id": "openrouter",
                "role": "worker",
                "prompt": SMOKE_PROMPT,
                "project_dir": project_arg,
                "model": OPENROUTER_MODEL,
            })),
        )
        .map_err(|error| {
            SmokeFailure::new(
                &correlation_id,
                runtime,
                OPENROUTER_MODEL,
                "agent_start",
                error,
            )
        })?;
    let managed_agent_id = started
        .pointer("/snapshot/managed_agent_id")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            SmokeFailure::new(
                &correlation_id,
                runtime,
                OPENROUTER_MODEL,
                "agent_start",
                format!("response omitted managed agent id: {started}"),
            )
        })?;
    poll_openrouter(http, &correlation_id, managed_agent_id)
}

fn poll_openrouter(
    http: &DaemonHttpClient,
    correlation_id: &str,
    managed_agent_id: &str,
) -> Result<LiveAgentSmokeReport, SmokeFailure> {
    let runtime = "openrouter";
    let deadline = Instant::now() + SMOKE_TIMEOUT;
    loop {
        let inspect_path = format!("/v1/managed-agents/acp/inspect?session_id={correlation_id}");
        let inspect = http
            .request_json(Method::GET, &inspect_path, None)
            .map_err(|error| {
                SmokeFailure::new(
                    correlation_id,
                    runtime,
                    OPENROUTER_MODEL,
                    "state_poll",
                    error,
                )
            })?;
        let agent = inspect["agents"].as_array().and_then(|agents| {
            agents
                .iter()
                .find(|agent| agent["managed_agent_id"] == managed_agent_id)
        });
        let terminal_result =
            agent.and_then(|agent| agent.pointer("/session_state/last_turn_result"));
        if let Some(terminal_result) = terminal_result {
            let terminal_status = terminal_result["stop_reason"].as_str().unwrap_or("unknown");
            let effective_model = agent.and_then(openrouter_effective_model);
            let report = terminal_result["report"]
                .as_str()
                .filter(|report| !report.trim().is_empty())
                .ok_or_else(|| {
                    SmokeFailure::new(
                        correlation_id,
                        runtime,
                        OPENROUTER_MODEL,
                        "result_collection",
                        "terminal result omitted a complete report",
                    )
                })?;
            if effective_model.as_deref() != Some(OPENROUTER_MODEL) {
                return Err(SmokeFailure::new(
                    correlation_id,
                    runtime,
                    OPENROUTER_MODEL,
                    "model_selection",
                    format!("effective model was {effective_model:?}"),
                ));
            }
            if terminal_status != "end_turn" {
                return Err(SmokeFailure::new(
                    correlation_id,
                    runtime,
                    OPENROUTER_MODEL,
                    "execution",
                    format!("terminal status was {terminal_status}"),
                ));
            }
            return Ok(completed_report(
                correlation_id,
                runtime,
                OPENROUTER_MODEL,
                effective_model,
                terminal_status,
                report.to_owned(),
            ));
        }
        if agent
            .and_then(|agent| agent["pending_permissions"].as_u64())
            .is_some_and(|count| count > 0)
        {
            permissions::reject_pending_permissions(http, managed_agent_id).map_err(|error| {
                SmokeFailure::new(
                    correlation_id,
                    runtime,
                    OPENROUTER_MODEL,
                    "permission_resolution",
                    error,
                )
            })?;
        }
        transcript::fail_on_openrouter_error(http, correlation_id)?;
        if Instant::now() >= deadline {
            return Err(transcript::timeout_failure(http, correlation_id, &inspect));
        }
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

fn openrouter_effective_model(agent: &Value) -> Option<String> {
    agent
        .pointer("/session_state/config_options")
        .and_then(Value::as_array)?
        .iter()
        .find(|option| option["id"] == "model")?
        .get("current_value")?
        .as_str()
        .map(ToOwned::to_owned)
}

fn run_codex(
    home: &Path,
    xdg: &Path,
    project: &Path,
    http: &DaemonHttpClient,
) -> Result<LiveAgentSmokeReport, SmokeFailure> {
    let runtime = "codex";
    let session = start_session_via_http(
        home,
        xdg,
        project.to_str().expect("UTF-8 project"),
        "headless-live-codex",
        "Codex headless live smoke",
        SMOKE_PROMPT,
    );
    let correlation_id = session.session_id.clone();
    let start_path = format!("/v1/sessions/{correlation_id}/managed-agents/codex");
    let started = http
        .request_json(
            Method::POST,
            &start_path,
            Some(json!({
                "prompt": SMOKE_PROMPT,
                "mode": "report",
                "model": CODEX_MODEL,
            })),
        )
        .map_err(|error| {
            SmokeFailure::new(&correlation_id, runtime, CODEX_MODEL, "agent_start", error)
        })?;
    let run_id = started
        .pointer("/snapshot/run_id")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            SmokeFailure::new(
                &correlation_id,
                runtime,
                CODEX_MODEL,
                "agent_start",
                format!("response omitted Codex run id: {started}"),
            )
        })?;
    let deadline = Instant::now() + SMOKE_TIMEOUT;
    loop {
        let snapshot = http
            .request_json(Method::GET, &format!("/v1/managed-agents/{run_id}"), None)
            .map_err(|error| {
                SmokeFailure::new(&correlation_id, runtime, CODEX_MODEL, "state_poll", error)
            })?;
        let run = &snapshot["snapshot"];
        let status = run["status"].as_str().unwrap_or("unknown");
        if !matches!(status, "queued" | "running" | "waiting_approval") {
            let effective_model = codex_effective_model(run);
            if status != "completed" {
                return Err(SmokeFailure::new(
                    &correlation_id,
                    runtime,
                    CODEX_MODEL,
                    "execution",
                    format!("terminal status={status} error={:?}", run["error"]),
                ));
            }
            let report = run["final_message"]
                .as_str()
                .filter(|value| !value.trim().is_empty());
            let report = report.ok_or_else(|| {
                SmokeFailure::new(
                    &correlation_id,
                    runtime,
                    CODEX_MODEL,
                    "result_collection",
                    "completed run omitted final_message",
                )
            })?;
            if effective_model.as_deref() != Some(CODEX_MODEL) {
                return Err(SmokeFailure::new(
                    &correlation_id,
                    runtime,
                    CODEX_MODEL,
                    "model_evidence",
                    format!("effective model was {effective_model:?}"),
                ));
            }
            return Ok(completed_report(
                &correlation_id,
                runtime,
                CODEX_MODEL,
                effective_model,
                status,
                report.to_owned(),
            ));
        }
        if Instant::now() >= deadline {
            return Err(SmokeFailure::new(
                &correlation_id,
                runtime,
                CODEX_MODEL,
                "state_poll",
                "timed out waiting for terminal status",
            ));
        }
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

fn codex_effective_model(run: &Value) -> Option<String> {
    run["events"].as_array()?.iter().rev().find_map(|event| {
        if !matches!(
            event["kind"].as_str(),
            Some("thread/start" | "thread/resume")
        ) {
            return None;
        }
        event["payload"]["model"].as_str().map(ToOwned::to_owned)
    })
}

fn completed_report(
    correlation_id: &str,
    runtime: &str,
    requested_model: &str,
    effective_model: Option<String>,
    terminal_status: &str,
    report: String,
) -> LiveAgentSmokeReport {
    LiveAgentSmokeReport {
        correlation_id: correlation_id.to_owned(),
        runtime: runtime.to_owned(),
        requested_model: requested_model.to_owned(),
        effective_model,
        terminal_status: terminal_status.to_owned(),
        report: Some(report),
        failure_stage: None,
        error: None,
    }
}

fn required_env(name: &str, runtime: &str, model: &str) -> String {
    let value = std::env::var(name).unwrap_or_default();
    assert!(
        !value.trim().is_empty(),
        "live agent smoke stopped before network: stage=credential runtime={runtime} requested_model={model}: {name} is missing or empty"
    );
    value
}
