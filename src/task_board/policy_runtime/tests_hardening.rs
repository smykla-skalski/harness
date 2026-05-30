use super::*;

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

    let runtime = PolicyRuntimeExecutor::new(
        PolicyRuntimeRepository::new(root.clone()),
        test_provider_registry(),
    );
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
    assert!(
        terminal <= 10,
        "terminal runs should be capped, got {terminal}"
    );
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
