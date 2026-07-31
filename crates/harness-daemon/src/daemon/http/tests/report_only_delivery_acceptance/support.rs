use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

use serde_json::json;
use tokio::task::JoinHandle;

use crate::daemon::db::{AgentTurnRunStatus, AsyncDaemonDb};
use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::http_paths;
use crate::daemon::service::task_board::with_read_only_launch_test_override;
use crate::daemon::task_board_read_only_coordinator::reconcile_task_board_read_only_workflows_with_runtime;
use crate::daemon::task_board_read_only_coordinator_tests::runtime::FakeReadOnlyRuntime;
use crate::task_board::TaskBoardWorkflowExecutionRecord;

use super::super::support::test_http_state_with_db_path;
use super::super::task_board_support::{
    dispatch_http_item, first_applied, get_json, post_json, put_json, serve_http,
};

pub(super) const DEEPSEEK_MODEL: &str = "deepseek/deepseek-v4-flash";
pub(super) const ADVANCED_HEAD: &str = "89abcdef0123456789abcdef0123456789abcdef";

pub(super) struct PublicReviewCase {
    pub(super) state: DaemonHttpState,
    pub(super) db: Arc<AsyncDaemonDb>,
    pub(super) runtime: FakeReadOnlyRuntime,
    pub(super) client: reqwest::Client,
    pub(super) base_url: String,
    pub(super) server: JoinHandle<()>,
    pub(super) database_path: PathBuf,
    pub(super) workspace: PathBuf,
    pub(super) item_id: String,
    pub(super) execution_id: String,
    pub(super) run_id: String,
    pub(super) frozen_head: String,
}

impl PublicReviewCase {
    pub(super) async fn reconcile(&self) {
        let now = crate::workspace::utc_now();
        let result =
            reconcile_task_board_read_only_workflows_with_runtime(&self.db, &self.runtime, &now, 8)
                .await
                .expect("reconcile report-only delivery");
        assert!(result.failures.is_empty(), "{:?}", result.failures);
    }

    pub(super) async fn report(&self) -> serde_json::Value {
        get_json(
            &self.client,
            &self.base_url,
            &format!(
                "{}/{}/review-report",
                http_paths::TASK_BOARD_ITEMS,
                self.item_id
            ),
        )
        .await
    }

    pub(super) async fn execution(&self) -> TaskBoardWorkflowExecutionRecord {
        self.db
            .task_board_workflow_execution(&self.execution_id)
            .await
            .expect("load acceptance execution")
            .expect("acceptance execution exists")
    }

    pub(super) async fn restart(mut self) -> Self {
        self.server.abort();
        let state = test_http_state_with_db_path(&self.database_path, "acceptance-restarted");
        let db = state.async_db.get().expect("restarted async db").clone();
        let runtime = FakeReadOnlyRuntime::new([]).with_durable_db(
            AsyncDaemonDb::connect(&self.database_path)
                .await
                .expect("reopen acceptance runtime store"),
        );
        runtime.set_head(&self.frozen_head);
        let (base_url, server) = serve_http(state.clone()).await;
        self.state = state;
        self.db = db;
        self.runtime = runtime;
        self.base_url = base_url;
        self.server = server;
        self
    }
}

impl Drop for PublicReviewCase {
    fn drop(&mut self) {
        self.server.abort();
    }
}

pub(super) async fn start_public_review(
    sandbox: &Path,
    label: &str,
    immutable_content: &str,
) -> PublicReviewCase {
    let case_root = sandbox.join(format!("report-only-{label}"));
    let origin = case_root.join("origin");
    std::fs::create_dir_all(&case_root).expect("create acceptance case root");
    harness_testkit::init_git_repo_with_seed(&origin);
    let frozen_head = git_head(&origin);
    let launched_head = frozen_head.clone();
    with_read_only_launch_test_override(&frozen_head, async {
        start_public_review_with_override(
            &case_root,
            &origin,
            label,
            immutable_content,
            launched_head,
        )
        .await
    })
    .await
}

async fn start_public_review_with_override(
    case_root: &Path,
    origin: &Path,
    label: &str,
    immutable_content: &str,
    frozen_head: String,
) -> PublicReviewCase {
    let database_path = case_root.join("harness.db");
    let state = test_http_state_with_db_path(&database_path, "acceptance");
    let db = state.async_db.get().expect("acceptance async db").clone();
    let (base_url, server) = serve_http(state.clone()).await;
    let client = reqwest::Client::new();
    let item_id = format!("requested-review-{label}");

    post_json(
        &client,
        &base_url,
        http_paths::POLICY_CANVASES_SPAWN_REQUIRES_LIVE_POLICY,
        json!({ "enabled": false }),
    )
    .await;
    let created = post_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ITEMS,
        json!({
            "id": item_id,
            "title": format!("Requested review {label}"),
            "body": immutable_content,
            "status": "inbox",
            "workflow_kind": "pr_review",
            "execution_repository": "example/compass",
            "external_refs": [{
                "provider": "github",
                "external_id": "example/compass#17",
                "url": "https://github.com/example/compass/pull/17"
            }]
        }),
    )
    .await;
    assert_eq!(created["status"], "inbox");
    let moved = put_json(
        &client,
        &base_url,
        &format!("{}/{}", http_paths::TASK_BOARD_ITEMS, item_id),
        json!({ "status": "todo" }),
    )
    .await;
    assert_eq!(moved["status"], "todo");
    assert_eq!(moved["agent_mode"], "evaluate");

    let dispatch = dispatch_http_item(&client, &base_url, &item_id, origin).await;
    assert!(
        dispatch["failures"].is_null()
            || dispatch["failures"].as_array().is_some_and(Vec::is_empty),
        "{dispatch}"
    );
    let applied = first_applied(&dispatch);
    let execution_id = applied["item"]["workflow"]["execution_id"]
        .as_str()
        .expect("dispatched execution id")
        .to_owned();
    let workspace = PathBuf::from(
        applied["item"]["workflow"]["worktree"]
            .as_str()
            .expect("dispatched worktree"),
    );
    let runtime_store = AsyncDaemonDb::connect(&database_path)
        .await
        .expect("open acceptance runtime store");
    let runtime = FakeReadOnlyRuntime::new([]).with_durable_db(runtime_store);
    runtime.set_head(&frozen_head);
    runtime.set_immutable_content(immutable_content);
    let mut case = PublicReviewCase {
        state,
        db,
        runtime,
        client,
        base_url,
        server,
        database_path,
        workspace,
        item_id,
        execution_id,
        run_id: String::new(),
        frozen_head,
    };
    case.reconcile().await;
    case.reconcile().await;
    let execution = case.execution().await;
    case.run_id = execution
        .attempts
        .first()
        .expect("running review attempt")
        .idempotency_key
        .clone();
    assert_eq!(case.runtime.start_count(), 1);
    case
}

pub(super) async fn finish_run(
    db: &AsyncDaemonDb,
    run_id: &str,
    status: AgentTurnRunStatus,
    report: Option<&str>,
    detail: Option<&str>,
) {
    let mut run = db
        .agent_turn_run(run_id)
        .await
        .expect("load acceptance run")
        .expect("acceptance run exists");
    run.status = status;
    run.actual_model = Some(DEEPSEEK_MODEL.into());
    run.report = report.map(str::to_owned);
    match status {
        AgentTurnRunStatus::Failed => run.error = detail.map(str::to_owned),
        AgentTurnRunStatus::Cancelled => run.stop_reason = detail.map(str::to_owned),
        _ => {}
    }
    run.updated_at = crate::workspace::utc_now();
    db.save_agent_turn_run(&run)
        .await
        .expect("save terminal acceptance run");
}

fn git_head(origin: &Path) -> String {
    let output = Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(origin)
        .output()
        .expect("resolve acceptance HEAD");
    assert!(output.status.success(), "{output:?}");
    String::from_utf8(output.stdout)
        .expect("UTF-8 acceptance HEAD")
        .trim()
        .to_owned()
}

pub(super) fn workspace_status(workspace: &Path) -> String {
    let output = Command::new("git")
        .args(["status", "--porcelain=v1", "--untracked-files=all"])
        .current_dir(workspace)
        .output()
        .expect("read acceptance workspace status");
    assert!(output.status.success(), "{output:?}");
    String::from_utf8(output.stdout).expect("UTF-8 acceptance workspace status")
}
