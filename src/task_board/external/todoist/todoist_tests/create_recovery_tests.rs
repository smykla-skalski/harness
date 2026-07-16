use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;

use super::*;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::{
    ExternalCreateLease, ExternalCreateProbe, ExternalCreateRequest,
};

#[tokio::test]
async fn todoist_create_recovery_replays_exact_persisted_request() {
    let response = r#"{"id":"remote-1","content":"Provider title","description":"Provider body","project_id":null,"is_completed":true,"updated_at":null}"#;
    let (endpoint, captured, handle) =
        spawn_sequence_mock(vec![("200 OK", response), ("200 OK", response)]);
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let recovery = client
        .external_create_recovery()
        .expect("Todoist create recovery");
    let request = ExternalCreateRequest::new(
        "task-1",
        "persisted-create-key",
        "Persisted title",
        "Persisted body",
        "provider-project",
    );
    let lease = CountingLease::default();

    let created = recovery
        .create_started(&request, &lease)
        .await
        .expect("create started");
    let recovered = recovery
        .recover_existing(&request, &lease)
        .await
        .expect("recover existing");

    assert_exact_provider_task(&created);
    assert_eq!(recovered, ExternalCreateProbe::Found(created));
    assert_eq!(lease.renewals.load(Ordering::SeqCst), 2);
    handle.join().expect("mock server");
    let captured = captured.lock().expect("captured requests");
    assert_eq!(captured.len(), 2);
    assert_eq!(captured[0].body, captured[1].body);
    for request in captured.iter() {
        assert_eq!(request.method, "POST");
        assert_eq!(request.path, "/tasks");
        assert_eq!(request.authorization.as_deref(), Some("Bearer token"));
        assert_eq!(request.request_id.as_deref(), Some("persisted-create-key"));
        let body = body_json(&request.body);
        assert_eq!(body["content"], "Persisted title");
        assert_eq!(body["description"], "Persisted body");
        assert_eq!(body["project_id"], "provider-project");
    }
}

#[tokio::test]
async fn todoist_unfiltered_create_recovery_omits_all_scope_sentinel() {
    let response =
        r#"{"id":"remote-1","content":"Provider title","description":"","project_id":null}"#;
    let (endpoint, captured, handle) = spawn_json_mock(response);
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let recovery = client
        .external_create_recovery()
        .expect("Todoist create recovery");
    let request = ExternalCreateRequest::new(
        "task-1",
        "persisted-create-key",
        "Persisted title",
        "",
        TODOIST_ALL_SCOPE,
    );
    let lease = CountingLease::default();

    recovery
        .create_started(&request, &lease)
        .await
        .expect("create unfiltered task");

    handle.join().expect("mock server");
    let captured = captured.lock().expect("captured request");
    assert_eq!(captured.request_id.as_deref(), Some("persisted-create-key"));
    let body = body_json(&captured.body);
    assert_eq!(body["content"], "Persisted title");
    assert!(body.get("description").is_none());
    assert!(body.get("project_id").is_none());
}

#[test]
fn todoist_create_recovery_supports_only_configured_targets() {
    let mut scoped =
        TodoistSyncClient::new_with_api_base("token", "https://todoist.invalid").expect("client");
    scoped.import_project_ids = vec!["project-1".into()];
    let scoped_recovery = scoped.external_create_recovery().expect("scoped recovery");

    assert!(scoped_recovery.supports_target("project-1"));
    assert!(!scoped_recovery.supports_target("project-2"));
    assert!(!scoped_recovery.supports_target(""));

    let unscoped =
        TodoistSyncClient::new_with_api_base("token", "https://todoist.invalid").expect("client");
    let unscoped_recovery = unscoped
        .external_create_recovery()
        .expect("unscoped recovery");

    assert_eq!(unscoped_recovery.provider(), ExternalProvider::Todoist);
    assert!(unscoped_recovery.supports_target("project-2"));
    assert!(!unscoped_recovery.supports_target(" "));
}

#[tokio::test]
async fn todoist_create_recovery_renews_before_remote_io() {
    let client =
        TodoistSyncClient::new_with_api_base("token", "http://127.0.0.1:1").expect("client");
    let recovery = client
        .external_create_recovery()
        .expect("Todoist create recovery");
    let request = ExternalCreateRequest::new(
        "task-1",
        "persisted-create-key",
        "Persisted title",
        "Persisted body",
        "provider-project",
    );
    let lease = RejectingLease;

    let create_error = recovery
        .create_started(&request, &lease)
        .await
        .expect_err("stale create lease");
    let recover_error = recovery
        .recover_existing(&request, &lease)
        .await
        .expect_err("stale recovery lease");

    assert_eq!(create_error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(recover_error.code(), "WORKFLOW_CONCURRENT");
}

fn assert_exact_provider_task(task: &ExternalTask) {
    assert_eq!(task.reference.provider, ExternalProvider::Todoist);
    assert_eq!(task.reference.external_id, "remote-1");
    assert_eq!(
        task.reference.url.as_deref(),
        Some("https://app.todoist.com/app/task/remote-1")
    );
    assert_eq!(task.title, "Provider title");
    assert_eq!(task.body, "Provider body");
    assert_eq!(task.status, TaskBoardStatus::Done);
    assert_eq!(task.project_id, None);
    assert_eq!(task.updated_at, None);
}

#[derive(Default)]
struct CountingLease {
    renewals: AtomicUsize,
}

#[async_trait]
impl ExternalCreateLease for CountingLease {
    async fn renew(&self) -> Result<(), CliError> {
        self.renewals.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}

struct RejectingLease;

#[async_trait]
impl ExternalCreateLease for RejectingLease {
    async fn renew(&self) -> Result<(), CliError> {
        Err(CliErrorKind::concurrent_modification("stale create lease").into())
    }
}
