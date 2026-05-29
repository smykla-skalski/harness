use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use tempfile::tempdir;

use super::actions::{
    ReviewsPolicyActionExecutor, ReviewsPolicyProvider, reviews_auto_run_request,
};
use super::evidence::review_target_policy_evidence;
use crate::reviews::{
    ReviewMergeableState, ReviewPullRequestState, ReviewReviewStatus, ReviewTarget,
    ReviewTargetFlags,
};
use crate::task_board::github::GitHubMergeMethod;
use crate::task_board::policy_graph::PolicyWaitCondition;
use crate::task_board::policy_runtime::executor::PolicyRuntimeExecutor;
use crate::task_board::policy_runtime::models::{PolicyRunStatus, PolicyRunTrigger};
use crate::task_board::policy_runtime::providers::PolicyProviderRegistry;
use crate::task_board::policy_runtime::repository::PolicyRuntimeRepository;

#[test]
fn review_target_maps_into_policy_evidence() {
    let mut target = review_target_fixture();
    target.flags.is_draft = true;
    target.review_status = ReviewReviewStatus::ReviewRequired;
    target.mergeable = ReviewMergeableState::Conflicting;
    target.flags.policy_blocked = true;

    let evidence = review_target_policy_evidence(&target);

    assert_eq!(evidence.review_is_open, Some(true));
    assert_eq!(evidence.review_is_draft, Some(true));
    assert_eq!(evidence.review_review_required, Some(true));
    assert_eq!(evidence.review_has_no_decision, Some(false));
    assert_eq!(evidence.review_has_merge_conflicts, Some(true));
    assert_eq!(evidence.review_policy_blocked, Some(true));
    assert_eq!(evidence.review_viewer_can_update, Some(true));
}

#[tokio::test]
async fn reviews_provider_approves_then_waits_for_checks_before_merge() {
    let repository = test_runtime_repository();
    let executed_actions = Arc::new(Mutex::new(Vec::new()));
    let mut registry = PolicyProviderRegistry::default();
    registry.register(ReviewsPolicyProvider::new(TestReviewsActionExecutor {
        executed_actions: Arc::clone(&executed_actions),
    }));
    let runtime = PolicyRuntimeExecutor::new(repository, registry);

    let run = runtime
        .start(
            PolicyRunTrigger::Manual,
            reviews_auto_run_request(review_target_fixture(), GitHubMergeMethod::Squash),
        )
        .await
        .expect("execute reviews workflow");

    assert_eq!(run.steps[0].action_key, "reviews.approve");
    assert_eq!(run.status, PolicyRunStatus::Waiting);
    assert_eq!(
        *executed_actions.lock().expect("lock executed actions"),
        vec!["reviews.approve".to_owned()],
    );
    assert_eq!(
        run.waiting_on,
        Some(PolicyWaitCondition::Event {
            event_key: "reviews.checks_passed".to_owned(),
        }),
    );
}

fn test_runtime_repository() -> PolicyRuntimeRepository {
    let temp = tempdir().expect("create tempdir");
    let root = temp.path().to_path_buf();
    std::mem::forget(temp);
    PolicyRuntimeRepository::new(root)
}

fn review_target_fixture() -> ReviewTarget {
    ReviewTarget {
        pull_request_id: "pr_1272".to_owned(),
        repository_id: "repo_1".to_owned(),
        repository: "Kong/mink-vcp-manager".to_owned(),
        number: 1272,
        url: "https://github.com/Kong/mink-vcp-manager/pull/1272".to_owned(),
        state: ReviewPullRequestState::Open,
        head_sha: "abc123".to_owned(),
        mergeable: ReviewMergeableState::Mergeable,
        review_status: ReviewReviewStatus::ReviewRequired,
        check_status: crate::reviews::ReviewCheckStatus::Success,
        flags: ReviewTargetFlags {
            is_draft: false,
            policy_blocked: false,
            viewer_can_update: true,
        },
        viewer_can_merge_as_admin: false,
        required_failed_check_names: Vec::new(),
        check_suite_ids: vec!["check-suite-1".to_owned()],
    }
}

struct TestReviewsActionExecutor {
    executed_actions: Arc<Mutex<Vec<String>>>,
}

#[async_trait]
impl ReviewsPolicyActionExecutor for TestReviewsActionExecutor {
    async fn approve(&self, _target: &ReviewTarget) -> Result<(), crate::errors::CliError> {
        self.executed_actions
            .lock()
            .expect("lock executed actions")
            .push("reviews.approve".to_owned());
        Ok(())
    }

    async fn merge(
        &self,
        _target: &ReviewTarget,
        _method: GitHubMergeMethod,
    ) -> Result<(), crate::errors::CliError> {
        self.executed_actions
            .lock()
            .expect("lock executed actions")
            .push("reviews.merge".to_owned());
        Ok(())
    }
}
