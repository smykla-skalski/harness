use std::future::Future;
use std::task::{Context, Poll, Waker};

use super::fake::{FakeAgentTurnPlan, FakeAgentTurnRuntime};
use super::{
    AgentTurnFailure, AgentTurnFailureCategory, AgentTurnFailureStage, AgentTurnPullRequest,
    AgentTurnPullRequestContext, AgentTurnReadOnlyContent, AgentTurnRequest, AgentTurnRuntime,
    AgentTurnSourceFreshness, AgentTurnStatus,
};

const HEAD_REVISION: &str = "0123456789abcdef0123456789abcdef01234567";

#[test]
fn fake_runtime_completes_one_stable_result() {
    let runtime =
        FakeAgentTurnRuntime::new([FakeAgentTurnPlan::completed("complete report", "end_turn")]);
    let id = start_turn(&runtime, Some("model-a"));

    assert!(!id.as_str().is_empty());
    assert_eq!(
        ready(runtime.status(&id)).expect("queued status"),
        AgentTurnStatus::Queued
    );
    complete_turn(&runtime, &id);
    assert_completed_result(&runtime, &id);
}

fn complete_turn(runtime: &FakeAgentTurnRuntime, id: &super::AgentTurnId) {
    assert_eq!(
        runtime.advance(id).expect("advance running"),
        AgentTurnStatus::Running
    );
    assert_eq!(
        runtime.advance(id).expect("advance completed"),
        AgentTurnStatus::Completed
    );
}

fn assert_completed_result(runtime: &FakeAgentTurnRuntime, id: &super::AgentTurnId) {
    let result = ready(runtime.result(id))
        .expect("load result")
        .expect("completed result");
    assert_eq!(&result.correlation_id, id);
    assert_eq!(result.report, "complete report");
    assert_eq!(result.stop_reason, "end_turn");
    assert_result_models(&result);
    assert!(result.source_revision.is_none());
    assert_eq!(
        ready(runtime.cancel(id)).expect("cancel completed turn"),
        AgentTurnStatus::Completed
    );
    assert_eq!(
        ready(runtime.result(id)).expect("reload result"),
        Some(result)
    );
}

fn assert_result_models(result: &super::AgentTurnResult) {
    assert_eq!(result.requested_model.as_deref(), Some("model-a"));
    assert_eq!(result.effective_model.as_deref(), Some("model-a"));
}

#[test]
fn fake_runtime_exposes_failed_terminal_state_without_a_completed_result() {
    let expected = AgentTurnFailure::new(
        AgentTurnFailureCategory::RateLimited,
        AgentTurnFailureStage::Execution,
        "provider rate limit",
    );
    let runtime = FakeAgentTurnRuntime::new([FakeAgentTurnPlan::failed(expected.clone())]);
    let id = ready(runtime.start(AgentTurnRequest {
        prompt: "prepare report".into(),
        requested_model: None,
        pull_request: None,
    }))
    .expect("start turn");

    assert_eq!(
        runtime.advance(&id).expect("advance running"),
        AgentTurnStatus::Running
    );
    assert_eq!(
        runtime.advance(&id).expect("advance failed"),
        AgentTurnStatus::Failed
    );
    assert_eq!(
        ready(runtime.cancel(&id)).expect("cancel failed turn"),
        AgentTurnStatus::Failed
    );
    assert!(ready(runtime.result(&id)).expect("load result").is_none());
    assert_eq!(
        ready(runtime.failure(&id)).expect("load failure"),
        Some(expected)
    );
}

#[test]
fn cancellation_is_idempotent_and_terminal() {
    let runtime =
        FakeAgentTurnRuntime::new([FakeAgentTurnPlan::completed("unused report", "end_turn")]);
    let id = ready(runtime.start(AgentTurnRequest {
        prompt: "prepare report".into(),
        requested_model: None,
        pull_request: None,
    }))
    .expect("start turn");

    assert_eq!(
        ready(runtime.cancel(&id)).expect("cancel turn"),
        AgentTurnStatus::Cancelled
    );
    assert_eq!(
        ready(runtime.cancel(&id)).expect("cancel again"),
        AgentTurnStatus::Cancelled
    );
    assert_eq!(
        runtime.advance(&id).expect("advance cancelled"),
        AgentTurnStatus::Cancelled
    );
    let failure = ready(runtime.failure(&id))
        .expect("load cancellation")
        .expect("cancelled failure");
    assert_eq!(failure.category, AgentTurnFailureCategory::Cancelled);
    assert_eq!(failure.stage, AgentTurnFailureStage::Cancellation);
    assert!(!failure.automatic_retry_safe);
}

#[test]
fn shared_lifecycle_supports_dynamic_runtime_dispatch() {
    let runtime = FakeAgentTurnRuntime::new([FakeAgentTurnPlan::completed("report", "end_turn")]);
    let lifecycle: &dyn AgentTurnRuntime = &runtime;
    let id = ready(lifecycle.start(AgentTurnRequest {
        prompt: "prepare report".into(),
        requested_model: None,
        pull_request: None,
    }))
    .expect("start through trait");

    assert_eq!(lifecycle.runtime(), "fake");
    assert_eq!(
        ready(lifecycle.status(&id)).expect("status through trait"),
        AgentTurnStatus::Queued
    );
}

#[test]
fn fake_runtime_freezes_pull_request_head_in_the_terminal_result() {
    let runtime =
        FakeAgentTurnRuntime::new([FakeAgentTurnPlan::completed("complete report", "end_turn")]);
    let mut context = pull_request_context(HEAD_REVISION);
    let id = ready(runtime.start(AgentTurnRequest {
        prompt: "review this pull request".into(),
        requested_model: None,
        pull_request: Some(context.clone()),
    }))
    .expect("start source-bound turn");

    context.pull_request.head_revision = "f".repeat(40);
    context.content.pull_request.head_revision = "f".repeat(40);
    complete_turn(&runtime, &id);
    let result = ready(runtime.result(&id))
        .expect("load result")
        .expect("completed result");
    assert_eq!(result.source_revision.as_deref(), Some(HEAD_REVISION));
    assert_eq!(
        result
            .source_freshness(HEAD_REVISION)
            .expect("current source"),
        AgentTurnSourceFreshness::Current
    );
    assert_eq!(
        result
            .source_freshness(&"f".repeat(40))
            .expect("stale source"),
        AgentTurnSourceFreshness::Stale {
            reviewed_revision: HEAD_REVISION.into(),
            current_revision: "f".repeat(40),
        }
    );
}

#[test]
fn mismatched_pull_request_content_fails_before_consuming_a_fake_plan() {
    let runtime =
        FakeAgentTurnRuntime::new([FakeAgentTurnPlan::completed("complete report", "end_turn")]);
    let mut mismatched = pull_request_context(HEAD_REVISION);
    mismatched.content.pull_request.head_revision = "f".repeat(40);

    let error = ready(runtime.start(AgentTurnRequest {
        prompt: "review this pull request".into(),
        requested_model: None,
        pull_request: Some(mismatched),
    }))
    .expect_err("mismatched content must fail");
    assert_eq!(error.code(), "WORKFLOW_PARSE");

    let id = ready(runtime.start(AgentTurnRequest {
        prompt: "review this pull request".into(),
        requested_model: None,
        pull_request: Some(pull_request_context(HEAD_REVISION)),
    }))
    .expect("the only plan must remain available");
    complete_turn(&runtime, &id);
}

#[test]
fn pull_request_context_rejects_invalid_identity_and_empty_content() {
    let cases = [
        pull_request_context("ABCDEF0123456789abcdef0123456789abcdef01"),
        AgentTurnPullRequestContext {
            pull_request: AgentTurnPullRequest {
                repository: "missing-owner".into(),
                number: 1,
                head_revision: HEAD_REVISION.into(),
            },
            ..pull_request_context(HEAD_REVISION)
        },
        AgentTurnPullRequestContext {
            content: AgentTurnReadOnlyContent {
                body: "  ".into(),
                ..pull_request_context(HEAD_REVISION).content
            },
            ..pull_request_context(HEAD_REVISION)
        },
    ];

    for context in cases {
        let error = ready(runtime_for_validation().start(AgentTurnRequest {
            prompt: "review this pull request".into(),
            requested_model: None,
            pull_request: Some(context),
        }))
        .expect_err("invalid context must fail");
        assert_eq!(error.code(), "WORKFLOW_PARSE");
    }
}

fn runtime_for_validation() -> FakeAgentTurnRuntime {
    FakeAgentTurnRuntime::new([FakeAgentTurnPlan::completed("unused", "end_turn")])
}

fn pull_request_context(head_revision: &str) -> AgentTurnPullRequestContext {
    let pull_request = AgentTurnPullRequest {
        repository: "smykla-skalski/harness".into(),
        number: 894,
        head_revision: head_revision.into(),
    };
    AgentTurnPullRequestContext {
        pull_request: pull_request.clone(),
        content: AgentTurnReadOnlyContent {
            pull_request,
            body: "diff --git a/src/lib.rs b/src/lib.rs".into(),
        },
    }
}

fn ready<T>(future: impl Future<Output = T>) -> T {
    let waker = Waker::noop();
    let mut context = Context::from_waker(waker);
    let mut future = Box::pin(future);
    match future.as_mut().poll(&mut context) {
        Poll::Ready(value) => value,
        Poll::Pending => panic!("fake lifecycle future unexpectedly pending"),
    }
}

fn start_turn(runtime: &FakeAgentTurnRuntime, requested_model: Option<&str>) -> super::AgentTurnId {
    ready(runtime.start(AgentTurnRequest {
        prompt: "prepare report".into(),
        requested_model: requested_model.map(str::to_owned),
        pull_request: None,
    }))
    .expect("start turn")
}
