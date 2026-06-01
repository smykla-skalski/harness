use std::sync::{Arc, Mutex};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    HarnessMonitorAuditEventsRequest, ReviewsPolicyPreviewRequest, ReviewsPolicyRunStartRequest,
    ReviewsPolicyRunStatus, ReviewsPolicyStepType, ReviewsPolicyTrigger,
};
use crate::reviews::ReviewCheckStatus;
use crate::task_board::github::GitHubMergeMethod;
use crate::task_board::policy_graph::PolicyWaitCondition;
use crate::task_board::policy_runtime::executor::PolicyRuntimeExecutor;
use crate::task_board::policy_runtime::models::{PolicyRunStatus, PolicyWorkflowEvent};
use crate::task_board::policy_runtime::providers::PolicyProviderRegistry;
use crate::task_board::policy_runtime::repository::PolicyRuntimeRepository;

use super::reviews_policy_fixtures::{
    TestReviewsPolicyExecutor, approve_wait_merge_policy_graph, merge_only_policy_graph,
    review_target_fixture, reviews_policy_run_request, test_runtime_root,
    write_active_policy_graph,
};

#[tokio::test]
async fn reviews_policy_preview_and_start_runs() {
    let root = test_runtime_root();
    let recorded_actions = Arc::new(Mutex::new(Vec::new()));
    let target = review_target_fixture();
    write_active_policy_graph(&root, approve_wait_merge_policy_graph());

    let preview = super::super::reviews::policy::preview_reviews_policy_with_root(
        &root,
        &ReviewsPolicyPreviewRequest {
            workflow_id: "reviews_auto".to_owned(),
            target: target.clone(),
            method: GitHubMergeMethod::Squash,
        },
    )
    .expect("preview response");

    assert_eq!(
        preview.steps[0].action_key.as_deref(),
        Some("reviews.approve")
    );

    let started = super::super::reviews::policy::start_reviews_policy_run_with_executor(
        root,
        TestReviewsPolicyExecutor {
            recorded_actions: Arc::clone(&recorded_actions),
        },
        &ReviewsPolicyRunStartRequest {
            workflow_id: "reviews_auto".to_owned(),
            target,
            method: GitHubMergeMethod::Squash,
            trigger: ReviewsPolicyTrigger::Manual,
        },
    )
    .await
    .expect("start run");

    assert!(started.run_id.starts_with("reviews-auto-"));
    assert_eq!(started.status, ReviewsPolicyRunStatus::Waiting);
    assert!(!started.started_at.is_empty());
    assert!(!started.updated_at.is_empty());
    assert_eq!(started.steps.len(), 2);
    assert_eq!(started.steps[0].step_type, ReviewsPolicyStepType::Action);
    assert_eq!(
        started.steps[0].action_key.as_deref(),
        Some("reviews.approve")
    );
    assert_eq!(started.steps[1].step_type, ReviewsPolicyStepType::Wait);
    assert_eq!(
        started.steps[1]
            .waiting_on
            .as_ref()
            .and_then(|wait| wait.event_key.as_deref()),
        Some("reviews.checks_passed")
    );
    assert_eq!(
        *recorded_actions.lock().expect("lock recorded actions"),
        vec!["reviews.approve".to_owned()],
    );
}

#[tokio::test]
async fn reviews_policy_start_records_typed_audit_lifecycle_events() {
    let root = test_runtime_root();
    let recorded_actions = Arc::new(Mutex::new(Vec::new()));
    let target = review_target_fixture();
    write_active_policy_graph(&root, approve_wait_merge_policy_graph());
    let (_tmp, audit_db) = open_reviews_policy_audit_db().await;

    let started =
        super::super::reviews::policy::start_reviews_policy_run_with_executor_and_audit_db(
            root,
            TestReviewsPolicyExecutor {
                recorded_actions: Arc::clone(&recorded_actions),
            },
            &ReviewsPolicyRunStartRequest {
                workflow_id: "reviews_auto".to_owned(),
                target,
                method: GitHubMergeMethod::Squash,
                trigger: ReviewsPolicyTrigger::Manual,
            },
            Some(Arc::clone(&audit_db)),
        )
        .await
        .expect("start run with audit db");

    let response = audit_db
        .load_audit_events(&HarnessMonitorAuditEventsRequest {
            limit: Some(10),
            sources: vec!["policy".to_owned()],
            subject: Some("Kong/mink-vcp-manager#1272".to_owned()),
            ..Default::default()
        })
        .await
        .expect("load policy audit events");
    let action_keys = response
        .events
        .iter()
        .filter_map(|event| event.action_key.as_deref())
        .collect::<Vec<_>>();

    assert_eq!(started.status, ReviewsPolicyRunStatus::Waiting);
    assert!(action_keys.contains(&"policy.workflow.start"));
    assert!(action_keys.contains(&"policy.workflow.wait"));
    let start_event = response
        .events
        .iter()
        .find(|event| event.action_key.as_deref() == Some("policy.workflow.start"))
        .expect("policy start audit event");
    assert_eq!(
        start_event.correlation_id.as_deref(),
        Some(started.run_id.as_str())
    );
    assert_eq!(start_event.outcome, "success");
}

#[tokio::test]
async fn reviews_policy_preview_respects_authored_wait_workflow_even_when_legacy_auto_mode_blocks()
{
    let root = test_runtime_root();
    let mut target = review_target_fixture();
    target.check_status = ReviewCheckStatus::Failure;
    target.required_failed_check_names = vec!["ci".to_owned()];
    write_active_policy_graph(&root, approve_wait_merge_policy_graph());

    let preview = super::super::reviews::policy::preview_reviews_policy_with_root(
        &root,
        &ReviewsPolicyPreviewRequest {
            workflow_id: "reviews_auto".to_owned(),
            target,
            method: GitHubMergeMethod::Squash,
        },
    )
    .expect("preview response");

    assert!(preview.eligible);
    assert_eq!(preview.steps.len(), 3);
    assert_eq!(preview.steps[1].step_type, ReviewsPolicyStepType::Wait);
}

#[tokio::test]
async fn reviews_policy_resume_event_executes_remaining_steps() {
    let root = test_runtime_root();
    let recorded_actions = Arc::new(Mutex::new(Vec::new()));
    let target = review_target_fixture();
    write_active_policy_graph(&root, approve_wait_merge_policy_graph());

    let started = super::super::reviews::policy::start_reviews_policy_run_with_executor(
        root.clone(),
        TestReviewsPolicyExecutor {
            recorded_actions: Arc::clone(&recorded_actions),
        },
        &ReviewsPolicyRunStartRequest {
            workflow_id: "reviews_auto".to_owned(),
            target,
            method: GitHubMergeMethod::Squash,
            trigger: ReviewsPolicyTrigger::Manual,
        },
    )
    .await
    .expect("start waiting run");

    assert_eq!(started.status, ReviewsPolicyRunStatus::Waiting);

    let resumed = super::super::reviews::policy::resume_reviews_policy_event_with_executor(
        root,
        TestReviewsPolicyExecutor {
            recorded_actions: Arc::clone(&recorded_actions),
        },
        &PolicyWorkflowEvent::named("reviews.checks_passed", "Kong/mink-vcp-manager#1272"),
    )
    .await
    .expect("resume runs");

    assert_eq!(resumed.len(), 1);
    assert_eq!(resumed[0].status, ReviewsPolicyRunStatus::Completed);
    assert!(resumed[0].completed_at.is_some());
    assert_eq!(resumed[0].steps.len(), 3);
    assert_eq!(resumed[0].steps[2].step_type, ReviewsPolicyStepType::Action);
    assert_eq!(
        resumed[0].steps[2].action_key.as_deref(),
        Some("reviews.merge")
    );
    assert_eq!(
        *recorded_actions.lock().expect("lock recorded actions"),
        vec!["reviews.approve".to_owned(), "reviews.merge".to_owned()],
    );
}

#[tokio::test]
async fn reviews_policy_start_uses_authored_canvas_workflow() {
    let root = test_runtime_root();
    let recorded_actions = Arc::new(Mutex::new(Vec::new()));
    let target = review_target_fixture();
    write_active_policy_graph(&root, merge_only_policy_graph());

    let preview = super::super::reviews::policy::preview_reviews_policy_with_root(
        &root,
        &ReviewsPolicyPreviewRequest {
            workflow_id: "reviews_auto".to_owned(),
            target: target.clone(),
            method: GitHubMergeMethod::Squash,
        },
    )
    .expect("preview response");

    assert_eq!(preview.steps.len(), 1);
    assert_eq!(
        preview.steps[0].action_key.as_deref(),
        Some("reviews.merge")
    );

    let started = super::super::reviews::policy::start_reviews_policy_run_with_executor(
        root,
        TestReviewsPolicyExecutor {
            recorded_actions: Arc::clone(&recorded_actions),
        },
        &ReviewsPolicyRunStartRequest {
            workflow_id: "reviews_auto".to_owned(),
            target,
            method: GitHubMergeMethod::Squash,
            trigger: ReviewsPolicyTrigger::Manual,
        },
    )
    .await
    .expect("start authored workflow run");

    assert_eq!(started.status, ReviewsPolicyRunStatus::Completed);
    assert_eq!(
        *recorded_actions.lock().expect("lock recorded actions"),
        vec!["reviews.merge".to_owned()],
    );
}

#[tokio::test]
async fn reviews_policy_resume_timer_executes_remaining_steps() {
    let root = test_runtime_root();
    let recorded_actions = Arc::new(Mutex::new(Vec::new()));
    let target = review_target_fixture();
    let run_request = reviews_policy_run_request(
        target,
        GitHubMergeMethod::Squash,
        PolicyWaitCondition::Timer {
            duration_seconds: 60,
        },
    );
    let mut providers = PolicyProviderRegistry::default();
    providers.register(crate::reviews::policy::ReviewsPolicyProvider::new(
        TestReviewsPolicyExecutor {
            recorded_actions: Arc::clone(&recorded_actions),
        },
    ));
    let runtime = PolicyRuntimeExecutor::new(PolicyRuntimeRepository::new(root.clone()), providers);

    let started = runtime
        .start(
            crate::task_board::policy_runtime::models::PolicyRunTrigger::Manual,
            run_request,
        )
        .await
        .expect("start timer waiting run");

    assert_eq!(
        started.status,
        crate::task_board::policy_runtime::models::PolicyRunStatus::Waiting
    );
    assert_eq!(
        *recorded_actions.lock().expect("lock recorded actions"),
        vec!["reviews.approve".to_owned()],
    );

    let due_at = chrono::DateTime::parse_from_rfc3339(&started.updated_at)
        .expect("parse started wait time")
        .with_timezone(&chrono::Utc)
        + chrono::Duration::seconds(60);
    let resumed = super::super::reviews::policy::resume_due_reviews_policy_timers_with_executor_at(
        root,
        TestReviewsPolicyExecutor {
            recorded_actions: Arc::clone(&recorded_actions),
        },
        due_at,
    )
    .await
    .expect("resume timer runs");

    assert_eq!(resumed.len(), 1);
    assert_eq!(resumed[0].status, ReviewsPolicyRunStatus::Completed);
    assert_eq!(resumed[0].trigger, ReviewsPolicyTrigger::Timer);
    assert_eq!(
        *recorded_actions.lock().expect("lock recorded actions"),
        vec!["reviews.approve".to_owned(), "reviews.merge".to_owned()],
    );
}

#[tokio::test]
async fn background_reviews_policy_run_skips_terminal_run_for_same_head_sha() {
    let root = test_runtime_root();
    let target = review_target_fixture();
    write_active_policy_graph(&root, merge_only_policy_graph());

    let first =
        super::super::reviews::policy::maybe_start_background_reviews_policy_run_with_executor(
            root.clone(),
            TestReviewsPolicyExecutor {
                recorded_actions: Arc::new(Mutex::new(Vec::new())),
            },
            &target,
            GitHubMergeMethod::Squash,
        )
        .await
        .expect("start background run")
        .expect("background run should start");

    assert_eq!(first.status, ReviewsPolicyRunStatus::Completed);

    let second =
        super::super::reviews::policy::maybe_start_background_reviews_policy_run_with_executor(
            root.clone(),
            TestReviewsPolicyExecutor {
                recorded_actions: Arc::new(Mutex::new(Vec::new())),
            },
            &target,
            GitHubMergeMethod::Squash,
        )
        .await
        .expect("skip repeated background run");

    assert!(second.is_none());

    let mut updated_target = target.clone();
    updated_target.head_sha = "def456".to_owned();
    let restarted =
        super::super::reviews::policy::maybe_start_background_reviews_policy_run_with_executor(
            root.clone(),
            TestReviewsPolicyExecutor {
                recorded_actions: Arc::new(Mutex::new(Vec::new())),
            },
            &updated_target,
            GitHubMergeMethod::Squash,
        )
        .await
        .expect("restart background run for new head")
        .expect("background run should restart");

    assert_ne!(first.run_id, restarted.run_id);
}

#[tokio::test]
async fn background_reviews_policy_run_supersedes_stale_waiting_head() {
    let root = test_runtime_root();
    let target = review_target_fixture();
    write_active_policy_graph(&root, approve_wait_merge_policy_graph());

    let first =
        super::super::reviews::policy::maybe_start_background_reviews_policy_run_with_executor(
            root.clone(),
            TestReviewsPolicyExecutor {
                recorded_actions: Arc::new(Mutex::new(Vec::new())),
            },
            &target,
            GitHubMergeMethod::Squash,
        )
        .await
        .expect("start first waiting run")
        .expect("background run should start");

    assert_eq!(first.status, ReviewsPolicyRunStatus::Waiting);

    let mut updated_target = target.clone();
    updated_target.head_sha = "def456".to_owned();
    let second =
        super::super::reviews::policy::maybe_start_background_reviews_policy_run_with_executor(
            root.clone(),
            TestReviewsPolicyExecutor {
                recorded_actions: Arc::new(Mutex::new(Vec::new())),
            },
            &updated_target,
            GitHubMergeMethod::Squash,
        )
        .await
        .expect("start updated waiting run")
        .expect("background run should restart for new head");

    let repository = PolicyRuntimeRepository::new(root.clone());
    let runs = repository
        .runs_for_subject("reviews_auto", &target.subject_key())
        .expect("load runs");
    let current = runs
        .iter()
        .find(|run| run.run_id == second.run_id)
        .expect("current run");
    let stale = runs
        .iter()
        .find(|run| run.run_id == first.run_id)
        .expect("stale run");
    assert_eq!(current.status, PolicyRunStatus::Waiting);
    assert_eq!(stale.status, PolicyRunStatus::Cancelled);

    let ready = repository
        .runs_ready_for_event(&PolicyWorkflowEvent::named(
            "reviews.checks_passed",
            &target.subject_key(),
        ))
        .expect("load ready runs");
    assert_eq!(ready, vec![second.run_id]);
}

async fn open_reviews_policy_audit_db() -> (tempfile::TempDir, Arc<AsyncDaemonDb>) {
    let tmp = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&tmp.path().join("harness.db"))
        .await
        .expect("open async daemon db");
    (tmp, Arc::new(db))
}
