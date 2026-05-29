use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use tempfile::tempdir;

use async_trait::async_trait;

use super::executor::PolicyRuntimeExecutor;
use super::models::{
    PolicyActionDescriptor, PolicyRunRequest, PolicyRunStatus, PolicyRunStep, PolicyRunSubject,
    PolicyRunTrigger, PolicyWorkflowEvent, PolicyWorkflowRun, PolicyWorkflowStepType,
};
use super::providers::{
    PolicyActionExecution, PolicyActionProvider, PolicyExecutionContext, PolicyProviderRegistry,
};
use super::repository::PolicyRuntimeRepository;
use crate::task_board::policy_graph::PolicyWaitCondition;

#[test]
fn waiting_run_persists_and_resumes_on_matching_event() {
    let repository = test_runtime_repository();
    let run = PolicyWorkflowRun::waiting_for_event(
        "reviews_auto",
        PolicyRunSubject::review_pr("Kong/mink-vcp-manager#1272"),
        PolicyWaitCondition::Event {
            event_key: "reviews.checks_passed".to_owned(),
        },
    );

    repository.save(&run).expect("save run");
    let ready = repository
        .runs_ready_for_event(&PolicyWorkflowEvent::named(
            "reviews.checks_passed",
            "Kong/mink-vcp-manager#1272",
        ))
        .expect("query ready runs");

    assert_eq!(ready, vec![run.run_id.clone()]);
}

#[test]
fn timer_wait_becomes_ready_after_deadline() {
    let repository = test_runtime_repository();
    let mut run = PolicyWorkflowRun::new(
        "reviews_auto",
        PolicyRunSubject::review_pr("Kong/mink-vcp-manager#1272"),
        None,
        PolicyRunTrigger::Background,
        Vec::new(),
    );
    run.mark_waiting(
        PolicyWaitCondition::Timer {
            duration_seconds: 60,
        },
        0,
    );
    run.waiting_since = Some("2026-05-29T10:00:00Z".to_owned());
    repository.save(&run).expect("save timer run");

    let before_due = chrono::DateTime::parse_from_rfc3339("2026-05-29T10:00:59Z")
        .expect("parse before due time")
        .with_timezone(&chrono::Utc);
    assert!(
        repository
            .runs_ready_for_timer(before_due)
            .expect("query runs before due")
            .is_empty()
    );

    let at_due = chrono::DateTime::parse_from_rfc3339("2026-05-29T10:01:00Z")
        .expect("parse due time")
        .with_timezone(&chrono::Utc);
    let ready = repository
        .runs_ready_for_timer(at_due)
        .expect("query runs at due time");

    assert_eq!(
        ready.into_iter().map(|run| run.run_id).collect::<Vec<_>>(),
        vec![run.run_id]
    );
}

#[tokio::test]
async fn manual_start_reuses_existing_background_run_for_same_subject() {
    let registry = test_provider_registry();
    let repository = test_runtime_repository();
    let runtime = PolicyRuntimeExecutor::new(repository, registry);

    let first = runtime
        .start(
            PolicyRunTrigger::Background,
            review_run_request("Kong/mink-vcp-manager#1272", "abc123"),
        )
        .await
        .expect("start background run");
    let second = runtime
        .start(
            PolicyRunTrigger::Manual,
            review_run_request("Kong/mink-vcp-manager#1272", "abc123"),
        )
        .await
        .expect("reuse background run");

    assert_eq!(first.status, PolicyRunStatus::Waiting);
    assert_eq!(first.run_id, second.run_id);
    assert_eq!(second.trigger, PolicyRunTrigger::ManualNudge);
}

#[tokio::test]
async fn new_subject_fingerprint_cancels_stale_waiting_run() {
    let root = test_runtime_root();
    let repository = PolicyRuntimeRepository::new(root.clone());
    let runtime = PolicyRuntimeExecutor::new(repository, test_provider_registry());

    let first = runtime
        .start(
            PolicyRunTrigger::Background,
            review_run_request("Kong/mink-vcp-manager#1272", "abc123"),
        )
        .await
        .expect("start first waiting run");
    let second = runtime
        .start(
            PolicyRunTrigger::Background,
            review_run_request("Kong/mink-vcp-manager#1272", "def456"),
        )
        .await
        .expect("start updated waiting run");

    assert_ne!(first.run_id, second.run_id);

    let runs = PolicyRuntimeRepository::new(root.clone())
        .runs_for_subject("reviews_auto", "Kong/mink-vcp-manager#1272")
        .expect("load subject runs");
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

    let ready = PolicyRuntimeRepository::new(root)
        .runs_ready_for_event(&PolicyWorkflowEvent::named(
            "reviews.checks_passed",
            "Kong/mink-vcp-manager#1272",
        ))
        .expect("query ready runs");
    assert_eq!(ready, vec![second.run_id]);
}

#[tokio::test]
async fn event_resume_executes_remaining_steps_and_completes_run() {
    let root = test_runtime_root();
    let recorded_actions = Arc::new(Mutex::new(Vec::new()));
    let runtime = PolicyRuntimeExecutor::new(
        PolicyRuntimeRepository::new(root.clone()),
        logged_provider_registry(Arc::clone(&recorded_actions)),
    );

    let started = runtime
        .start(
            PolicyRunTrigger::Manual,
            review_run_request("Kong/mink-vcp-manager#1272", "abc123"),
        )
        .await
        .expect("start waiting run");

    assert_eq!(started.status, PolicyRunStatus::Waiting);
    assert_eq!(started.steps.len(), 2);
    assert_eq!(started.steps[0].step_type, PolicyWorkflowStepType::Action);
    assert_eq!(
        started.steps[0].action_key.as_deref(),
        Some("reviews.approve")
    );
    assert_eq!(started.steps[1].step_type, PolicyWorkflowStepType::Wait);
    assert_eq!(
        started.steps[1].waiting_on,
        Some(PolicyWaitCondition::Event {
            event_key: "reviews.checks_passed".to_owned(),
        })
    );
    assert_eq!(
        *recorded_actions.lock().expect("lock recorded actions"),
        vec!["reviews.approve".to_owned()],
    );

    let ready = PolicyRuntimeRepository::new(root)
        .runs_ready_for_event(&PolicyWorkflowEvent::named(
            "reviews.checks_passed",
            "Kong/mink-vcp-manager#1272",
        ))
        .expect("ready runs");
    let resumed = runtime
        .resume(&ready[0], PolicyRunTrigger::Event)
        .await
        .expect("resume run")
        .expect("existing run");

    assert_eq!(resumed.status, PolicyRunStatus::Completed);
    assert_eq!(resumed.steps.len(), 3);
    assert_eq!(resumed.steps[2].step_type, PolicyWorkflowStepType::Action);
    assert_eq!(
        resumed.steps[2].action_key.as_deref(),
        Some("reviews.merge")
    );
    assert!(resumed.completed_at.is_some());
    assert_eq!(
        *recorded_actions.lock().expect("lock recorded actions"),
        vec!["reviews.approve".to_owned(), "reviews.merge".to_owned()],
    );
}

#[tokio::test]
async fn failed_action_persists_failed_run_details() {
    let root = test_runtime_root();
    let runtime = PolicyRuntimeExecutor::new(
        PolicyRuntimeRepository::new(root.clone()),
        failing_provider_registry("reviews.merge"),
    );

    let error = runtime
        .start(
            PolicyRunTrigger::Manual,
            PolicyRunRequest {
                workflow_id: "reviews_auto".to_owned(),
                subject: PolicyRunSubject::review_pr("Kong/mink-vcp-manager#1272"),
                subject_fingerprint: Some("abc123".to_owned()),
                steps: vec![PolicyRunStep::Action(PolicyActionDescriptor {
                    provider: "reviews".to_owned(),
                    action_key: "reviews.merge".to_owned(),
                    payload: None,
                })],
            },
        )
        .await
        .expect_err("persist failed run");

    assert!(
        error.to_string().contains("simulated action failure"),
        "unexpected error: {error}"
    );

    let runs = PolicyRuntimeRepository::new(root)
        .runs_for_subject("reviews_auto", "Kong/mink-vcp-manager#1272")
        .expect("load runs");
    let failed = runs.first().expect("failed run");

    assert_eq!(failed.status, PolicyRunStatus::Failed);
    assert!(
        failed
            .error_message
            .as_deref()
            .is_some_and(|message| message.contains("simulated action failure"))
    );
    assert!(failed.completed_at.is_some());
    assert!(failed.steps.is_empty());
}

#[test]
fn claim_waiting_run_transitions_once_under_contention() {
    let repository = test_runtime_repository();
    let run = PolicyWorkflowRun::waiting_for_event(
        "reviews_auto",
        PolicyRunSubject::review_pr("Kong/mink-vcp-manager#1272"),
        PolicyWaitCondition::Event {
            event_key: "reviews.checks_passed".to_owned(),
        },
    );
    repository.save(&run).expect("save waiting run");

    let first = repository
        .claim_waiting_run(&run.run_id, PolicyRunTrigger::Event)
        .expect("first claim");
    let second = repository
        .claim_waiting_run(&run.run_id, PolicyRunTrigger::Event)
        .expect("second claim");

    assert!(first.is_some(), "first claim should win the waiting run");
    assert_eq!(first.expect("claimed run").status, PolicyRunStatus::Running);
    assert!(
        second.is_none(),
        "second claim must not re-take an already-running run"
    );
}

#[test]
fn manual_nudge_does_not_extend_timer_deadline() {
    let repository = test_runtime_repository();
    let mut run = PolicyWorkflowRun::new(
        "reviews_auto",
        PolicyRunSubject::review_pr("Kong/mink-vcp-manager#1272"),
        None,
        PolicyRunTrigger::Background,
        Vec::new(),
    );
    run.mark_waiting(
        PolicyWaitCondition::Timer {
            duration_seconds: 60,
        },
        0,
    );
    // The wait started at a fixed anchor; a manual nudge then bumps
    // updated_at to wall-clock now (far past the anchor's deadline).
    run.waiting_since = Some("2026-05-29T10:00:00Z".to_owned());
    run.nudge_manually();
    repository.save(&run).expect("save nudged timer run");

    let at_due = chrono::DateTime::parse_from_rfc3339("2026-05-29T10:01:00Z")
        .expect("parse due time")
        .with_timezone(&chrono::Utc);
    let ready = repository
        .runs_ready_for_timer(at_due)
        .expect("query runs at anchor deadline");

    assert_eq!(
        ready.into_iter().map(|run| run.run_id).collect::<Vec<_>>(),
        vec![run.run_id],
        "deadline must stay anchored to waiting_since despite the nudge"
    );
}

#[test]
fn completed_run_with_residual_timer_is_not_timer_ready() {
    let repository = test_runtime_repository();
    let mut run = PolicyWorkflowRun::new(
        "reviews_auto",
        PolicyRunSubject::review_pr("Kong/mink-vcp-manager#1272"),
        None,
        PolicyRunTrigger::Background,
        Vec::new(),
    );
    // Force an inconsistent record: completed status but a residual timer
    // wait. The status guard must keep it out of the timer-ready set.
    run.status = PolicyRunStatus::Completed;
    run.waiting_on = Some(PolicyWaitCondition::Timer {
        duration_seconds: 1,
    });
    run.waiting_since = Some("2020-01-01T00:00:00Z".to_owned());
    repository.save(&run).expect("save run");

    let now = chrono::Utc::now();
    assert!(
        repository
            .runs_ready_for_timer(now)
            .expect("query timer runs")
            .is_empty()
    );
}

#[tokio::test]
async fn stale_running_run_is_reclaimed_so_a_fresh_run_can_start() {
    let root = test_runtime_root();
    let stale_updated_at = (chrono::Utc::now() - chrono::Duration::hours(1)).to_rfc3339();
    let mut stuck = PolicyWorkflowRun::new(
        "reviews_auto",
        PolicyRunSubject::review_pr("Kong/mink-vcp-manager#1272"),
        Some("abc123".to_owned()),
        PolicyRunTrigger::Manual,
        Vec::new(),
    );
    stuck.updated_at = stale_updated_at;
    PolicyRuntimeRepository::new(root.clone())
        .save(&stuck)
        .expect("save stuck running run");

    let runtime =
        PolicyRuntimeExecutor::new(PolicyRuntimeRepository::new(root.clone()), test_provider_registry());
    let fresh = runtime
        .start(
            PolicyRunTrigger::Manual,
            review_run_request("Kong/mink-vcp-manager#1272", "abc123"),
        )
        .await
        .expect("start fresh run after reclaiming the stuck one");

    assert_ne!(fresh.run_id, stuck.run_id);
    let runs = PolicyRuntimeRepository::new(root)
        .runs_for_subject("reviews_auto", "Kong/mink-vcp-manager#1272")
        .expect("load runs");
    let reclaimed = runs
        .iter()
        .find(|run| run.run_id == stuck.run_id)
        .expect("stuck run still recorded");
    assert_eq!(reclaimed.status, PolicyRunStatus::Cancelled);
}

#[test]
fn begin_run_prunes_old_terminal_runs_but_keeps_active() {
    let repository = test_runtime_repository();
    for index in 0..15 {
        let mut run = PolicyWorkflowRun::new(
            "reviews_auto",
            PolicyRunSubject::review_pr("Kong/mink-vcp-manager#1272"),
            None,
            PolicyRunTrigger::Background,
            Vec::new(),
        );
        run.run_id = format!("old-run-{index:02}");
        run.created_at = format!("2026-05-29T10:00:{index:02}Z");
        run.mark_completed();
        repository.save(&run).expect("save old run");
    }

    let fresh = PolicyWorkflowRun::new(
        "reviews_auto",
        PolicyRunSubject::review_pr("Kong/mink-vcp-manager#1272"),
        Some("fp".to_owned()),
        PolicyRunTrigger::Manual,
        Vec::new(),
    );
    let _ = repository
        .begin_run(fresh, PolicyRunTrigger::Manual, chrono::Utc::now())
        .expect("begin run");

    let runs = repository
        .runs_for_subject("reviews_auto", "Kong/mink-vcp-manager#1272")
        .expect("load runs");
    let terminal = runs
        .iter()
        .filter(|run| {
            matches!(
                run.status,
                PolicyRunStatus::Completed | PolicyRunStatus::Failed | PolicyRunStatus::Cancelled
            )
        })
        .count();
    assert!(terminal <= 10, "terminal runs should be capped, got {terminal}");
    assert!(
        runs.iter().any(|run| matches!(
            run.status,
            PolicyRunStatus::Running | PolicyRunStatus::Waiting
        )),
        "the freshly started run must survive pruning",
    );
}

#[tokio::test]
async fn provider_registry_dispatches_by_domain() {
    let recorded = Arc::new(Mutex::new(Vec::new()));
    let mut registry = PolicyProviderRegistry::default();
    registry.register(DomainProbeProvider {
        domain: "reviews",
        recorded: Arc::clone(&recorded),
    });
    registry.register(DomainProbeProvider {
        domain: "tasks",
        recorded: Arc::clone(&recorded),
    });
    let ctx = PolicyExecutionContext {
        workflow_id: "wf".to_owned(),
        subject: PolicyRunSubject::review_pr("Kong/mink-vcp-manager#1272"),
        trigger: PolicyRunTrigger::Manual,
    };

    registry
        .execute(
            &PolicyActionDescriptor {
                provider: "tasks".to_owned(),
                action_key: "tasks.create".to_owned(),
                payload: None,
            },
            &ctx,
        )
        .await
        .expect("dispatch to tasks provider");

    assert_eq!(
        *recorded.lock().expect("lock recorded"),
        vec!["tasks::tasks.create".to_owned()],
        "the action must route to the provider whose domain matches",
    );

    let missing = registry
        .execute(
            &PolicyActionDescriptor {
                provider: "unregistered".to_owned(),
                action_key: "noop".to_owned(),
                payload: None,
            },
            &ctx,
        )
        .await;
    assert!(missing.is_err(), "unknown provider domain must error");
}

struct DomainProbeProvider {
    domain: &'static str,
    recorded: Arc<Mutex<Vec<String>>>,
}

#[async_trait]
impl PolicyActionProvider for DomainProbeProvider {
    fn domain(&self) -> &'static str {
        self.domain
    }

    async fn execute(
        &self,
        action: &PolicyActionDescriptor,
        _ctx: &PolicyExecutionContext,
    ) -> Result<PolicyActionExecution, crate::errors::CliError> {
        self.recorded
            .lock()
            .expect("lock recorded")
            .push(format!("{}::{}", self.domain, action.action_key));
        Ok(PolicyActionExecution {
            action_key: action.action_key.clone(),
        })
    }
}

fn test_runtime_root() -> PathBuf {
    let temp = tempdir().expect("create tempdir");
    let root = temp.path().to_path_buf();
    std::mem::forget(temp);
    root
}

fn test_runtime_repository() -> PolicyRuntimeRepository {
    PolicyRuntimeRepository::new(test_runtime_root())
}

fn test_provider_registry() -> PolicyProviderRegistry {
    let mut registry = PolicyProviderRegistry::default();
    registry.register(TestActionProvider {
        recorded_actions: None,
        fail_action: None,
    });
    registry
}

fn logged_provider_registry(recorded_actions: Arc<Mutex<Vec<String>>>) -> PolicyProviderRegistry {
    let mut registry = PolicyProviderRegistry::default();
    registry.register(TestActionProvider {
        recorded_actions: Some(recorded_actions),
        fail_action: None,
    });
    registry
}

fn failing_provider_registry(action_key: &str) -> PolicyProviderRegistry {
    let mut registry = PolicyProviderRegistry::default();
    registry.register(TestActionProvider {
        recorded_actions: None,
        fail_action: Some(action_key.to_owned()),
    });
    registry
}

fn review_run_request(subject_key: &str, head_sha: &str) -> PolicyRunRequest {
    PolicyRunRequest {
        workflow_id: "reviews_auto".to_owned(),
        subject: PolicyRunSubject::review_pr(subject_key),
        subject_fingerprint: Some(head_sha.to_owned()),
        steps: vec![
            PolicyRunStep::Action(PolicyActionDescriptor {
                provider: "reviews".to_owned(),
                action_key: "reviews.approve".to_owned(),
                payload: None,
            }),
            PolicyRunStep::Wait(PolicyWaitCondition::Event {
                event_key: "reviews.checks_passed".to_owned(),
            }),
            PolicyRunStep::Action(PolicyActionDescriptor {
                provider: "reviews".to_owned(),
                action_key: "reviews.merge".to_owned(),
                payload: None,
            }),
        ],
    }
}

struct TestActionProvider {
    recorded_actions: Option<Arc<Mutex<Vec<String>>>>,
    fail_action: Option<String>,
}

#[async_trait]
impl PolicyActionProvider for TestActionProvider {
    fn domain(&self) -> &'static str {
        "reviews"
    }

    async fn execute(
        &self,
        action: &PolicyActionDescriptor,
        _ctx: &PolicyExecutionContext,
    ) -> Result<PolicyActionExecution, crate::errors::CliError> {
        if self
            .fail_action
            .as_ref()
            .is_some_and(|fail_action| fail_action == &action.action_key)
        {
            return Err(crate::errors::CliErrorKind::workflow_parse(
                "simulated action failure".to_owned(),
            )
            .into());
        }
        if let Some(recorded_actions) = &self.recorded_actions {
            recorded_actions
                .lock()
                .expect("lock recorded actions")
                .push(action.action_key.clone());
        }
        Ok(PolicyActionExecution {
            action_key: action.action_key.clone(),
        })
    }
}
