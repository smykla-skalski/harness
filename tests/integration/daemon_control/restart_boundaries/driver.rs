//! The restart driver and its runtime seam.
//!
//! The driver enters through the daemon's public task-board HTTP surface and
//! owns the initial daemon process; a restart hands the replacement to the
//! daemon control CLI, which the final `stop` (or the drop guard) reaps. Every
//! failure report carries the stage plus a correlation id so a green run and a
//! failing run point at the same execution.

use super::super::*;

/// A named pipeline stage a restart driver can fail at. Every failure report
/// carries the stage plus the ticket correlation id so a green run and a
/// failing run point at the same execution.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Stage {
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
pub(super) struct RestartFailure {
    stage: Stage,
    correlation_id: String,
    detail: String,
}

impl RestartFailure {
    pub(super) fn new(
        stage: Stage,
        correlation_id: impl Into<String>,
        detail: impl Into<String>,
    ) -> Self {
        Self {
            stage,
            correlation_id: correlation_id.into(),
            detail: detail.into(),
        }
    }

    pub(super) fn describe(&self) -> String {
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
pub(super) trait WorkflowRuntime {
    fn label(&self) -> &'static str;
    fn attach(&self, home: &Path, xdg: &Path) -> Result<(), RestartFailure>;
}

/// Deterministic runtime with no live provider and no bridge. Reaching the
/// admission boundary needs neither, so attach is a no-op and the outcomes stay
/// reproducible without credentials.
pub(super) struct FakeRuntime;

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
pub(super) struct RestartDriver {
    home: PathBuf,
    xdg: PathBuf,
    daemon: Option<ManagedChild>,
    endpoint: String,
    token: String,
    runtime: Box<dyn WorkflowRuntime>,
    stopped: bool,
}

impl RestartDriver {
    pub(super) fn start(base: &Path, runtime: Box<dyn WorkflowRuntime>) -> Self {
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
            stopped: false,
        }
    }

    #[expect(
        clippy::needless_pass_by_value,
        reason = "owned by value so callers pass owned json! temporaries; borrowed per attempt"
    )]
    fn send(&self, method: &str, path: &str, body: Option<Value>) -> (u16, Value) {
        let url = format!(
            "{}/{}",
            self.endpoint.trim_end_matches('/'),
            path.trim_start_matches('/')
        );
        let runtime = Runtime::new().expect("runtime");
        let client = reqwest::Client::new();
        let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
        loop {
            let mut builder = match method {
                "POST" => client.post(&url),
                "PUT" => client.put(&url),
                "GET" => client.get(&url),
                other => panic!("unsupported method {other}"),
            }
            .bearer_auth(&self.token)
            .timeout(DAEMON_HTTP_TIMEOUT);
            if let Some(body) = body.as_ref() {
                builder = builder.json(body);
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

    pub(super) fn import_inbox_ticket(
        &self,
        id: &str,
        workflow_kind: &str,
    ) -> Result<Value, RestartFailure> {
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

    pub(super) fn admit_to_todo(&self, id: &str) -> Result<Value, RestartFailure> {
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

    pub(super) fn get_item(&self, id: &str) -> Result<Value, RestartFailure> {
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

    pub(super) fn open_spawn_gate(&self) {
        let (status, body) = self.send(
            "POST",
            "/v1/policy-canvases/spawn-requires-live-policy",
            Some(json!({ "enabled": false })),
        );
        assert_eq!(status, 200, "open spawn gate: {body}");
    }

    pub(super) fn dispatch_plan(&self, id: &str) -> Result<Value, RestartFailure> {
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

    pub(super) fn dispatch_real(&self, id: &str, project: &Path) -> Result<Value, RestartFailure> {
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
    pub(super) fn restart(&mut self, correlation: &str) -> Result<(), RestartFailure> {
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

    pub(super) fn stop(mut self) {
        let output = run_harness(&self.home, &self.xdg, &["daemon", "stop"]);
        assert!(
            output.status.success(),
            "stop failed: {}",
            output_text(&output)
        );
        // Wait for the owned initial child to exit rather than leaving its kill
        // to `ManagedChild::drop`. After a restart the child was taken, so the
        // CLI stop above is what reaps the detached replacement.
        if let Some(mut daemon) = self.daemon.take() {
            wait_for_child_exit(&mut daemon);
        }
        self.stopped = true;
    }
}

impl Drop for RestartDriver {
    fn drop(&mut self) {
        // A panic between `restart` and `stop` leaves `self.daemon` empty and the
        // detached replacement daemon running, so best-effort stop it here rather
        // than leak a daemon across a failed test. The owned child, when present,
        // is reaped by `ManagedChild`'s own drop.
        if !self.stopped {
            let _ = run_harness(&self.home, &self.xdg, &["daemon", "stop"]);
        }
    }
}
