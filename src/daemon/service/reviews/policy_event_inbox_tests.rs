use async_trait::async_trait;
use tempfile::tempdir;

use super::*;
use crate::reviews::ReviewTarget;
use crate::task_board::github::GitHubMergeMethod;
use crate::task_board::policy_graph::PolicyWaitCondition;
use crate::task_board::policy_runtime::models::{
    PolicyRunStatus, PolicyRunStep, PolicyRunSubject, PolicyRunTrigger, PolicyWorkflowRun,
};
use crate::task_board::policy_runtime::repository::PolicyRuntimeRepository;

#[derive(Clone)]
struct NoopExecutor;

#[async_trait]
impl ReviewsPolicyActionExecutor for NoopExecutor {
    async fn approve(&self, _target: &ReviewTarget) -> Result<(), CliError> {
        Ok(())
    }

    async fn merge(
        &self,
        _target: &ReviewTarget,
        _method: GitHubMergeMethod,
    ) -> Result<(), CliError> {
        Ok(())
    }
}

fn waiting_run(subject_key: &str) -> PolicyWorkflowRun {
    let wait = PolicyWaitCondition::Event {
        event_key: REVIEWS_CHECKS_PASSED_EVENT.to_owned(),
    };
    let mut run = PolicyWorkflowRun::new(
        "reviews_auto",
        PolicyRunSubject::review_pr(subject_key),
        Some("head-sha".to_owned()),
        PolicyRunTrigger::Background,
        vec![PolicyRunStep::Wait(wait.clone())],
    );
    run.mark_waiting(wait, 1);
    run
}

#[tokio::test]
async fn draining_the_inbox_resumes_a_waiting_run_and_clears_the_event() {
    let dir = tempdir().expect("tempdir");
    let root = dir.path().to_path_buf();
    let repository = PolicyRuntimeRepository::new(root.clone());
    let run = waiting_run("owner/repo#1");
    let run_id = run.run_id.clone();
    repository.save(&run).expect("seed waiting run");

    let inbox = PolicyEventInbox::new(root.clone());
    inbox
        .publish(PolicyWorkflowEvent::named(
            REVIEWS_CHECKS_PASSED_EVENT,
            "owner/repo#1",
        ))
        .expect("publish event");

    let resumed = resume_due_reviews_policy_events_with_executor_at(root.clone(), NoopExecutor)
        .await
        .expect("drain inbox");

    assert_eq!(resumed.len(), 1, "the waiting run is resumed");
    assert!(
        inbox.pending().expect("pending").is_empty(),
        "delivered event removed from inbox"
    );
    let resumed_run = repository
        .run_by_id(&run_id)
        .expect("load run")
        .expect("run exists");
    assert_eq!(resumed_run.status, PolicyRunStatus::Completed);
}

#[tokio::test]
async fn draining_an_inbox_event_without_a_matching_run_clears_it() {
    let dir = tempdir().expect("tempdir");
    let root = dir.path().to_path_buf();
    let inbox = PolicyEventInbox::new(root.clone());
    inbox
        .publish(PolicyWorkflowEvent::named(
            REVIEWS_CHECKS_PASSED_EVENT,
            "owner/repo#7",
        ))
        .expect("publish event");

    let resumed = resume_due_reviews_policy_events_with_executor_at(root.clone(), NoopExecutor)
        .await
        .expect("drain inbox");

    assert!(resumed.is_empty(), "no waiting run to resume");
    assert!(
        inbox.pending().expect("pending").is_empty(),
        "unmatched event is still consumed so it cannot pile up"
    );
}
