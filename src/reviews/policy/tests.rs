use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use serde_json::json;
use tempfile::tempdir;

use super::actions::{
    ReviewsPolicyActionExecutor, ReviewsPolicyProvider, authored_reviews_policy_plan,
};
use super::evidence::review_target_policy_evidence;
use crate::reviews::{
    ReviewMergeableState, ReviewPullRequestState, ReviewReviewStatus, ReviewTarget,
    ReviewTargetFlags,
};
use crate::task_board::github::GitHubMergeMethod;
use crate::task_board::policy_graph::PolicyWaitCondition;
use crate::task_board::policy_runtime::executor::PolicyRuntimeExecutor;
use crate::task_board::policy_runtime::models::{
    PolicyActionDescriptor, PolicyRunRequest, PolicyRunStatus, PolicyRunStep, PolicyRunSubject,
    PolicyRunTrigger,
};
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
            reviews_policy_run_request(
                review_target_fixture(),
                GitHubMergeMethod::Squash,
                PolicyWaitCondition::Event {
                    event_key: "reviews.checks_passed".to_owned(),
                },
            ),
        )
        .await
        .expect("execute reviews workflow");

    assert_eq!(run.steps[0].action_key.as_deref(), Some("reviews.approve"));
    assert_eq!(run.steps[1].waiting_on, run.waiting_on);
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

#[test]
fn run_start_request_reads_merge_method_from_method_key() {
    // The Swift client snake-cases its field names, so the merge method must
    // arrive under `method` (matching the existing merge/auto requests). This
    // is the wire contract the Monitor app has to satisfy.
    let body = json!({
        "workflow_id": "reviews_auto",
        "target": review_target_fixture(),
        "method": "merge",
        "trigger": "manual",
    });
    let request: crate::reviews::ReviewsPolicyRunStartRequest =
        serde_json::from_value(body).expect("deserialize start request");
    assert_eq!(request.method, GitHubMergeMethod::Merge);
}

#[test]
fn run_start_request_ignores_legacy_merge_method_key() {
    // A payload that misnames the field as `merge_method` must fall back to
    // the default instead of silently honoring it, so the drift cannot be
    // mistaken for a working contract.
    let body = json!({
        "workflow_id": "reviews_auto",
        "target": review_target_fixture(),
        "merge_method": "merge",
        "trigger": "manual",
    });
    let request: crate::reviews::ReviewsPolicyRunStartRequest =
        serde_json::from_value(body).expect("deserialize start request");
    assert_eq!(request.method, GitHubMergeMethod::default());
}

#[test]
fn preview_request_reads_merge_method_from_method_key() {
    let body = json!({
        "workflow_id": "reviews_auto",
        "target": review_target_fixture(),
        "method": "rebase",
    });
    let request: crate::reviews::ReviewsPolicyPreviewRequest =
        serde_json::from_value(body).expect("deserialize preview request");
    assert_eq!(request.method, GitHubMergeMethod::Rebase);
}

#[test]
fn authored_plan_seeds_reviews_auto_and_is_actionable() {
    let temp = tempdir().expect("create tempdir");
    let plan = authored_reviews_policy_plan(
        temp.path(),
        "reviews_auto",
        &review_target_fixture(),
        GitHubMergeMethod::Merge,
    )
    .expect("plan reviews auto");

    assert!(
        plan.actionable,
        "expected actionable plan, reason: {:?}",
        plan.reason
    );
    assert!(
        matches!(plan.steps.first(), Some(PolicyRunStep::Action(action)) if action.action_key == "reviews.approve"),
        "first step should approve",
    );
    assert!(
        matches!(
            plan.steps.get(1),
            Some(PolicyRunStep::Wait(PolicyWaitCondition::Event { event_key })) if event_key == "reviews.checks_passed"
        ),
        "second step should wait for checks",
    );
    assert!(
        matches!(plan.steps.get(2), Some(PolicyRunStep::Action(action)) if action.action_key == "reviews.merge"),
        "third step should merge",
    );
}

#[test]
fn seeded_reviews_auto_compiles_to_expected_step_shape() {
    // Compilation regression guard: the seeded `reviews_auto` workflow must
    // compile into approve -> wait(reviews.checks_passed) -> merge, in that
    // exact order. A future compiler or seed change that reshapes the canvas
    // (drops a step, reorders, renames the resume event) trips this test
    // before it can silently change what Auto executes.
    let temp = tempdir().expect("create tempdir");
    let plan = authored_reviews_policy_plan(
        temp.path(),
        "reviews_auto",
        &review_target_fixture(),
        GitHubMergeMethod::Merge,
    )
    .expect("plan reviews auto");

    assert!(
        plan.actionable,
        "expected actionable plan, reason: {:?}",
        plan.reason
    );

    let step_kinds = plan
        .steps
        .iter()
        .map(|step| match step {
            PolicyRunStep::Action(action) => format!("action:{}", action.action_key),
            PolicyRunStep::Wait(PolicyWaitCondition::Event { event_key }) => {
                format!("wait_event:{event_key}")
            }
            PolicyRunStep::Wait(PolicyWaitCondition::Timer { duration_seconds }) => {
                format!("wait_timer:{duration_seconds}")
            }
        })
        .collect::<Vec<_>>();

    assert_eq!(
        step_kinds,
        vec![
            "action:reviews.approve".to_owned(),
            "wait_event:reviews.checks_passed".to_owned(),
            "action:reviews.merge".to_owned(),
        ],
    );
}

#[test]
fn authored_plan_blocks_when_viewer_cannot_update() {
    let mut target = review_target_fixture();
    target.flags.viewer_can_update = false;
    let temp = tempdir().expect("create tempdir");
    let plan = authored_reviews_policy_plan(
        temp.path(),
        "reviews_auto",
        &target,
        GitHubMergeMethod::Squash,
    )
    .expect("plan reviews auto");

    assert!(!plan.actionable, "ineligible target must not be actionable");
    assert!(plan.reason.is_some());
}

#[test]
fn authored_plan_resolves_mixed_case_workflow_id() {
    let temp = tempdir().expect("create tempdir");
    let plan = authored_reviews_policy_plan(
        temp.path(),
        "Reviews_Auto",
        &review_target_fixture(),
        GitHubMergeMethod::Squash,
    )
    .expect("plan reviews auto");

    assert!(
        plan.actionable,
        "mixed-case id should resolve, reason: {:?}",
        plan.reason
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

fn reviews_policy_run_request(
    target: ReviewTarget,
    method: GitHubMergeMethod,
    wait: PolicyWaitCondition,
) -> PolicyRunRequest {
    let merge_target = target.clone();
    PolicyRunRequest {
        workflow_id: "reviews_auto".to_owned(),
        subject: PolicyRunSubject::review_pr(&format!("{}#{}", target.repository, target.number)),
        subject_fingerprint: Some(target.head_sha.clone()),
        steps: vec![
            PolicyRunStep::Action(PolicyActionDescriptor {
                provider: "reviews".to_owned(),
                action_key: "reviews.approve".to_owned(),
                payload: Some(json!({
                    "target": target,
                    "merge_method": null,
                })),
            }),
            PolicyRunStep::Wait(wait),
            PolicyRunStep::Action(PolicyActionDescriptor {
                provider: "reviews".to_owned(),
                action_key: "reviews.merge".to_owned(),
                payload: Some(json!({
                    "target": merge_target,
                    "merge_method": method,
                })),
            }),
        ],
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
