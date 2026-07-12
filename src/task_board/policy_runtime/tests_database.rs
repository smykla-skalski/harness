use std::sync::Arc;

use tempfile::tempdir;

use super::executor::PolicyRuntimeExecutor;
use super::models::{
    PolicyRunRequest, PolicyRunStatus, PolicyRunStep, PolicyRunSubject, PolicyRunTrigger,
};
use super::providers::PolicyProviderRegistry;
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::policy_graph::PolicyWaitCondition;

#[tokio::test]
async fn executor_starts_and_resumes_the_same_database_run() {
    let dir = tempdir().expect("tempdir");
    let database = Arc::new(
        AsyncDaemonDb::connect(&dir.path().join("harness.db"))
            .await
            .expect("open database"),
    );
    let runtime = PolicyRuntimeExecutor::new_database(
        Arc::clone(&database),
        PolicyProviderRegistry::default(),
    );
    let started = runtime
        .start(
            PolicyRunTrigger::Manual,
            PolicyRunRequest {
                workflow_id: "reviews_auto".to_owned(),
                subject: PolicyRunSubject::review_pr("owner/repo#42"),
                subject_fingerprint: Some("head-sha".to_owned()),
                steps: vec![PolicyRunStep::Wait(PolicyWaitCondition::Event {
                    event_key: "reviews.checks_passed".to_owned(),
                })],
            },
        )
        .await
        .expect("start run");
    assert_eq!(started.status, PolicyRunStatus::Waiting);
    assert_eq!(
        database
            .policy_run_by_id(&started.run_id)
            .await
            .expect("load waiting run")
            .expect("waiting run exists")
            .status,
        PolicyRunStatus::Waiting
    );

    let resumed = runtime
        .resume(&started.run_id, PolicyRunTrigger::Event)
        .await
        .expect("resume run")
        .expect("waiting run was claimed");
    assert_eq!(resumed.status, PolicyRunStatus::Completed);
    assert_eq!(
        database
            .policy_run_by_id(&started.run_id)
            .await
            .expect("load completed run")
            .expect("completed run exists")
            .status,
        PolicyRunStatus::Completed
    );
}
