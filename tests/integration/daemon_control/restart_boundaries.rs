//! Cross real daemon restart boundaries for board-driven pull-request work.
//!
//! The closed #880 driver reopened a database connection per tick inside one
//! process against one fake runtime, and its fixtures began after admission,
//! so a green run never proved recovery at the boundaries #1003 names. This
//! driver supersedes it: it enters through the daemon's public task-board HTTP
//! surface, starts from a Todo ticket rather than a prebuilt running execution,
//! and each restart replaces the real `harness-daemon` process (and the runtime
//! state it reopens) exactly as `daemon_restart_replaces_running_manual_daemon`
//! does. Outcomes stay deterministic because nothing live is attached: no
//! provider credential, bridge, check, or GitHub call is made, so the agent,
//! check, and GitHub results are whatever the daemon computes with nothing
//! attached, which is stable across runs. An optional live adapter swaps in
//! through `WorkflowRuntime` without changing the driver.
//!
//! Every failure report carries the stage plus a correlation id - the ticket
//! being driven, or the daemon instance for a restart - so a green run and a
//! failing run point at the same execution.
//!
//! Production mid-launch restart recovery stays in #919; these tests exercise
//! the recovery that already exists at the admission boundary of umbrella #997.

use super::*;

/// A named pipeline stage a restart driver can fail at. Every failure report
/// carries the stage plus the ticket correlation id so a green run and a
/// failing run point at the same execution.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stage {
    Import,
    Admit,
    DispatchReadiness,
    Restart,
    Recover,
}

impl Stage {
    fn label(self) -> &'static str {
        match self {
            Stage::Import => "import",
            Stage::Admit => "admit",
            Stage::DispatchReadiness => "dispatch_readiness",
            Stage::Restart => "daemon_restart",
            Stage::Recover => "recover",
        }
    }
}

/// A failure at a named stage, tied to the ticket correlation identity.
#[derive(Debug)]
struct RestartFailure {
    stage: Stage,
    correlation_id: String,
    detail: String,
}

impl RestartFailure {
    fn new(stage: Stage, correlation_id: impl Into<String>, detail: impl Into<String>) -> Self {
        Self {
            stage,
            correlation_id: correlation_id.into(),
            detail: detail.into(),
        }
    }

    fn describe(&self) -> String {
        format!(
            "stage={} correlation_id={}: {}",
            self.stage.label(),
            self.correlation_id,
            self.detail
        )
    }
}

/// The runtime seam. Deterministic tests use `FakeRuntime`; an optional live
/// adapter implements the same trait to attach a real bridge and provider
/// instead, and the driver drives either without change. `attach` runs once at
/// construction and again after every restart, mirroring how a live adapter
/// would have to reattach its bridge to the freshly spawned daemon.
trait WorkflowRuntime {
    fn label(&self) -> &'static str;
    fn attach(&self, home: &Path, xdg: &Path) -> Result<(), RestartFailure>;
}

/// Deterministic runtime with no live provider and no bridge. Reaching the
/// admission boundary needs neither, so attach is a no-op and the outcomes stay
/// reproducible without credentials.
struct FakeRuntime;

impl WorkflowRuntime for FakeRuntime {
    fn label(&self) -> &'static str {
        "fake"
    }

    fn attach(&self, _home: &Path, _xdg: &Path) -> Result<(), RestartFailure> {
        Ok(())
    }
}

/// Drives one Todo ticket through the public daemon surface across real
/// restarts. Owns the initial daemon process; a restart hands the replacement
/// to the daemon control CLI, which the final `stop` reaps.
struct RestartDriver {
    home: PathBuf,
    xdg: PathBuf,
    daemon: Option<ManagedChild>,
    endpoint: String,
    token: String,
    runtime: Box<dyn WorkflowRuntime>,
}

impl RestartDriver {
    fn start(base: &Path, runtime: Box<dyn WorkflowRuntime>) -> Self {
        let home = base.join("home");
        let xdg = base.join("xdg");
        std::fs::create_dir_all(&home).expect("create home");
        std::fs::create_dir_all(&xdg).expect("create xdg");

        let daemon = spawn_daemon_serve(&home, &xdg);
        let _status = wait_for_daemon_ready(&home, &xdg);
        let (endpoint, token) = current_daemon_endpoint_and_token(&home, &xdg);
        runtime
            .attach(&home, &xdg)
            .unwrap_or_else(|failure| panic!("{}", failure.describe()));
        Self {
            home,
            xdg,
            daemon: Some(daemon),
            endpoint,
            token,
            runtime,
        }
    }

    #[expect(
        clippy::needless_pass_by_value,
        reason = "retries clone the caller body for each request attempt"
    )]
    fn send(&self, method: &str, path: &str, body: Option<Value>) -> (u16, Value) {
        let url = format!(
            "{}/{}",
            self.endpoint.trim_end_matches('/'),
            path.trim_start_matches('/')
        );
        let runtime = Runtime::new().expect("runtime");
        let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
        loop {
            let client = reqwest::Client::new();
            let mut builder = match method {
                "POST" => client.post(&url),
                "PUT" => client.put(&url),
                "GET" => client.get(&url),
                other => panic!("unsupported method {other}"),
            }
            .bearer_auth(&self.token)
            .timeout(DAEMON_HTTP_TIMEOUT);
            if let Some(body) = body.clone() {
                builder = builder.json(&body);
            }
            match runtime.block_on(async { builder.send().await }) {
                Ok(response) => {
                    let status = response.status().as_u16();
                    let json = runtime
                        .block_on(async { response.json::<Value>().await.expect("json body") });
                    return (status, json);
                }
                Err(error) if error.is_timeout() || error.is_connect() || error.is_request() => {
                    assert!(
                        Instant::now() < deadline,
                        "daemon {method} {path}: {error:?}"
                    );
                    thread::sleep(DAEMON_WAIT_INTERVAL);
                }
                Err(error) => panic!("daemon {method} {path}: {error:?}"),
            }
        }
    }

    fn import_todo_seed(&self, id: &str, workflow_kind: &str) -> Result<Value, RestartFailure> {
        let (status, body) = self.send(
            "POST",
            "/v1/task-board/items",
            Some(json!({
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
            })),
        );
        if status != 200 {
            return Err(RestartFailure::new(
                Stage::Import,
                id,
                format!("HTTP {status}: {body}"),
            ));
        }
        Ok(body)
    }

    fn admit_to_todo(&self, id: &str) -> Result<Value, RestartFailure> {
        let (status, body) = self.send(
            "PUT",
            &format!("/v1/task-board/items/{id}"),
            Some(json!({ "status": "todo" })),
        );
        if status != 200 {
            return Err(RestartFailure::new(
                Stage::Admit,
                id,
                format!("HTTP {status}: {body}"),
            ));
        }
        Ok(body)
    }

    fn get_item(&self, id: &str) -> Result<Value, RestartFailure> {
        let (status, body) = self.send("GET", &format!("/v1/task-board/items/{id}"), None);
        if status != 200 {
            return Err(RestartFailure::new(
                Stage::Recover,
                id,
                format!("HTTP {status}: {body}"),
            ));
        }
        Ok(body)
    }

    fn open_spawn_gate(&self) {
        let (status, body) = self.send(
            "POST",
            "/v1/policy-canvases/spawn-requires-live-policy",
            Some(json!({ "enabled": false })),
        );
        assert_eq!(status, 200, "open spawn gate: {body}");
    }

    fn dispatch_plan(&self, id: &str) -> Result<Value, RestartFailure> {
        let (status, body) = self.send(
            "POST",
            "/v1/task-board/dispatch",
            Some(json!({ "item_id": id, "dry_run": true })),
        );
        if status != 200 {
            return Err(RestartFailure::new(
                Stage::DispatchReadiness,
                id,
                format!("HTTP {status}: {body}"),
            ));
        }
        let matching: Vec<Value> = body["plans"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|plan| plan["board_item_id"] == json!(id))
            .cloned()
            .collect();
        // Exactly one eligible plan is the anti-duplication signal: a restart
        // that re-admitted the ticket a second time would surface two.
        if matching.len() != 1 {
            return Err(RestartFailure::new(
                Stage::DispatchReadiness,
                id,
                format!(
                    "expected exactly one plan for {id}, got {}: {body}",
                    matching.len()
                ),
            ));
        }
        Ok(matching.into_iter().next().expect("matched plan"))
    }

    fn dispatch_real(&self, id: &str, project: &Path) -> Result<Value, RestartFailure> {
        let (status, body) = self.send(
            "POST",
            "/v1/task-board/dispatch",
            Some(json!({
                "item_id": id,
                "dry_run": false,
                "project_dir": project.to_string_lossy(),
            })),
        );
        if status != 200 {
            return Err(RestartFailure::new(
                Stage::DispatchReadiness,
                id,
                format!("HTTP {status}: {body}"),
            ));
        }
        Ok(body)
    }

    fn daemon_pid(&self) -> u32 {
        wait_for_daemon_ready(&self.home, &self.xdg)
            .manifest
            .expect("daemon manifest")
            .pid
    }

    /// Replace the running daemon process, mirroring
    /// `daemon_restart_replaces_running_manual_daemon`, then reopen the runtime
    /// state the fresh process now owns. `correlation` is the ticket being
    /// driven, so a restart failure names the same execution as the other
    /// stages.
    fn restart(&mut self, correlation: &str) -> Result<(), RestartFailure> {
        let before = self.daemon_pid();
        let output = run_harness(&self.home, &self.xdg, &["daemon", "restart"]);
        if !output.status.success() {
            return Err(RestartFailure::new(
                Stage::Restart,
                correlation,
                format!(
                    "restart command failed for {} runtime: {}",
                    self.runtime.label(),
                    output_text(&output)
                ),
            ));
        }
        if let Some(mut daemon) = self.daemon.take() {
            wait_for_child_exit(&mut daemon);
        }
        let after = self.daemon_pid();
        if after == before {
            return Err(RestartFailure::new(
                Stage::Restart,
                correlation,
                format!("restart did not replace the process (pid stayed {after})"),
            ));
        }
        let (endpoint, token) = current_daemon_endpoint_and_token(&self.home, &self.xdg);
        self.endpoint = endpoint;
        self.token = token;
        self.runtime.attach(&self.home, &self.xdg)
    }

    fn stop(self) {
        let output = run_harness(&self.home, &self.xdg, &["daemon", "stop"]);
        assert!(
            output.status.success(),
            "stop failed: {}",
            output_text(&output)
        );
    }
}

fn workflow_status(item: &Value) -> String {
    item["workflow"]["status"]
        .as_str()
        .unwrap_or("idle")
        .to_owned()
}

fn assert_not_blocked_on_approval(plan: &Value) {
    let readiness = &plan["readiness"];
    if readiness["state"] == json!("blocked") {
        assert_ne!(
            readiness["reason"]["kind"],
            json!("plan_approval"),
            "an imported pull request must never be stranded on plan approval: {plan}"
        );
    }
}

trait UnwrapOrReport<T> {
    fn or_report(self) -> T;
}

impl<T> UnwrapOrReport<T> for Result<T, RestartFailure> {
    fn or_report(self) -> T {
        self.unwrap_or_else(|failure| panic!("{}", failure.describe()))
    }
}

#[test]
fn an_admitted_review_resumes_exactly_once_across_a_real_daemon_restart() {
    let tmp = tempdir().expect("tempdir");
    let mut driver = RestartDriver::start(tmp.path(), Box::new(FakeRuntime));

    driver
        .import_todo_seed("restart-review", "pr_review")
        .or_report();
    let admitted = driver.admit_to_todo("restart-review").or_report();
    assert_eq!(admitted["agent_mode"], json!("evaluate"), "{admitted}");

    let plan = driver.dispatch_plan("restart-review").or_report();
    assert_not_blocked_on_approval(&plan);
    let before = driver.get_item("restart-review").or_report();
    assert_eq!(workflow_status(&before), "idle", "{before}");
    assert!(before["workflow"]["execution_id"].is_null(), "{before}");

    driver.restart("restart-review").or_report();

    // The board entry survived the real process, bootstrap, and db-reopen
    // boundary rather than being rebuilt or lost.
    let recovered = driver.get_item("restart-review").or_report();
    assert_eq!(recovered["status"], json!("todo"), "{recovered}");
    assert_eq!(recovered["agent_mode"], json!("evaluate"), "{recovered}");
    assert_eq!(
        workflow_status(&recovered),
        "idle",
        "the process replacement must not stamp a phantom execution: {recovered}"
    );
    assert!(
        recovered["workflow"]["execution_id"].is_null(),
        "the process replacement must not stamp a phantom execution: {recovered}"
    );

    // Resuming plans exactly one eligible step (dispatch_plan asserts the count)
    // and stamps no execution, so the restart neither advanced nor duplicated
    // the pipeline.
    let replan = driver.dispatch_plan("restart-review").or_report();
    assert_not_blocked_on_approval(&replan);
    let after = driver.get_item("restart-review").or_report();
    assert_eq!(workflow_status(&after), "idle", "{after}");
    assert!(
        after["workflow"]["execution_id"].is_null(),
        "resuming must leave exactly one eligible step, not a second execution: {after}"
    );

    driver.stop();
}

#[test]
fn a_failed_admission_stays_cleared_across_a_real_daemon_restart() {
    let tmp = tempdir().expect("tempdir");
    // A directory that exists but is not a git repository: the reservation
    // succeeds and stamps an Admitting execution, then preparation fails when it
    // tries to cut a worktree, so the ticket must roll back cleanly.
    let project = tmp.path().join("not-a-git-project");
    std::fs::create_dir_all(&project).expect("create project");
    let mut driver = RestartDriver::start(tmp.path(), Box::new(FakeRuntime));

    driver.import_todo_seed("restart-dep", "pr_fix").or_report();
    driver.admit_to_todo("restart-dep").or_report();
    driver.open_spawn_gate();

    let response = driver.dispatch_real("restart-dep", &project).or_report();
    let failures = response["failures"].as_array().expect("failures array");
    assert_eq!(
        failures.len(),
        1,
        "an unusable project must fail admission: {response}"
    );
    // The daemon's own failure payload names the ticket, and the report surfaces
    // that identity rather than a literal supplied by the test.
    let failed_id = failures[0]["board_item_id"]
        .as_str()
        .expect("failure names its board item");
    assert_eq!(failed_id, "restart-dep", "{response}");
    let report = RestartFailure::new(
        Stage::Recover,
        failed_id,
        failures[0]["message"]
            .as_str()
            .unwrap_or("preparation failed"),
    );
    assert!(
        report.describe().contains("correlation_id=restart-dep"),
        "{}",
        report.describe()
    );

    let cleared = driver.get_item("restart-dep").or_report();
    assert_ne!(
        cleared["workflow"]["status"],
        json!("admitting"),
        "{cleared}"
    );
    assert!(cleared["workflow"]["execution_id"].is_null(), "{cleared}");

    driver.restart("restart-dep").or_report();

    // The cleanup is durable across the real restart: the ticket is not
    // resurrected into Admitting and its dead execution stays gone.
    let recovered = driver.get_item("restart-dep").or_report();
    assert_ne!(
        recovered["workflow"]["status"],
        json!("admitting"),
        "{recovered}"
    );
    assert!(
        recovered["workflow"]["execution_id"].is_null(),
        "the dead execution must not survive the restart: {recovered}"
    );

    // Recovery leaves the ticket cleanly retryable exactly once, not stranded
    // and not carrying a duplicate of the pre-restart attempt.
    let replan = driver.dispatch_plan("restart-dep").or_report();
    assert_eq!(replan["board_item_id"], json!("restart-dep"), "{replan}");

    driver.stop();
}

#[test]
fn restart_failure_describes_stage_and_correlation() {
    let failure = RestartFailure::new(Stage::Restart, "ticket-42", "pid stayed 100");
    let described = failure.describe();
    assert!(described.contains("stage=daemon_restart"), "{described}");
    assert!(
        described.contains("correlation_id=ticket-42"),
        "{described}"
    );
    assert!(described.contains("pid stayed 100"), "{described}");
}
