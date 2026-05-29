use tempfile::tempdir;

use super::executor::PolicyRuntimeExecutor;
use super::models::{
    PolicyActionDescriptor, PolicyRunRequest, PolicyRunStatus, PolicyRunStep, PolicyRunSubject,
    PolicyRunTrigger, PolicyWorkflowEvent, PolicyWorkflowRun,
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
fn manual_start_reuses_existing_background_run_for_same_subject() {
    let registry = test_provider_registry();
    let repository = test_runtime_repository();
    let runtime = PolicyRuntimeExecutor::new(repository, registry);

    let first = runtime
        .start(PolicyRunTrigger::Background, review_run_request("Kong/mink-vcp-manager#1272"))
        .expect("start background run");
    let second = runtime
        .start(PolicyRunTrigger::Manual, review_run_request("Kong/mink-vcp-manager#1272"))
        .expect("reuse background run");

    assert_eq!(first.status, PolicyRunStatus::Waiting);
    assert_eq!(first.run_id, second.run_id);
    assert_eq!(second.trigger, PolicyRunTrigger::ManualNudge);
}

fn test_runtime_repository() -> PolicyRuntimeRepository {
    let temp = tempdir().expect("create tempdir");
    let root = temp.path().to_path_buf();
    std::mem::forget(temp);
    PolicyRuntimeRepository::new(root)
}

fn test_provider_registry() -> PolicyProviderRegistry {
    let mut registry = PolicyProviderRegistry::default();
    registry.register(TestActionProvider);
    registry
}

fn review_run_request(subject_key: &str) -> PolicyRunRequest {
    PolicyRunRequest {
        workflow_id: "reviews_auto".to_owned(),
        subject: PolicyRunSubject::review_pr(subject_key),
        steps: vec![
            PolicyRunStep::Action(PolicyActionDescriptor {
                provider: "reviews".to_owned(),
                action_key: "reviews.approve".to_owned(),
                payload: None,
            }),
            PolicyRunStep::Wait(PolicyWaitCondition::Event {
                event_key: "reviews.checks_passed".to_owned(),
            }),
        ],
    }
}

struct TestActionProvider;

impl PolicyActionProvider for TestActionProvider {
    fn domain(&self) -> &'static str {
        "reviews"
    }

    fn execute(
        &self,
        action: &PolicyActionDescriptor,
        _ctx: &PolicyExecutionContext,
    ) -> Result<PolicyActionExecution, crate::errors::CliError> {
        Ok(PolicyActionExecution {
            action_key: action.action_key.clone(),
        })
    }
}
