use std::future::Future;
use std::task::{Context, Poll, Waker};

use super::fake::{FakeAgentTurnPlan, FakeAgentTurnRuntime};
use super::{AgentTurnRequest, AgentTurnRuntime, AgentTurnStatus};

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
    assert_eq!(
        ready(runtime.cancel(id)).expect("cancel completed turn"),
        AgentTurnStatus::Completed
    );
    assert_eq!(
        ready(runtime.result(id)).expect("reload result"),
        Some(result)
    );
}

#[test]
fn fake_runtime_exposes_failed_terminal_state_without_a_completed_result() {
    let runtime = FakeAgentTurnRuntime::new([FakeAgentTurnPlan::fail()]);
    let id = ready(runtime.start(AgentTurnRequest {
        prompt: "prepare report".into(),
        requested_model: None,
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
}

#[test]
fn cancellation_is_idempotent_and_terminal() {
    let runtime =
        FakeAgentTurnRuntime::new([FakeAgentTurnPlan::completed("unused report", "end_turn")]);
    let id = ready(runtime.start(AgentTurnRequest {
        prompt: "prepare report".into(),
        requested_model: None,
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
}

#[test]
fn shared_lifecycle_supports_dynamic_runtime_dispatch() {
    let runtime = FakeAgentTurnRuntime::new([FakeAgentTurnPlan::completed("report", "end_turn")]);
    let lifecycle: &dyn AgentTurnRuntime = &runtime;
    let id = ready(lifecycle.start(AgentTurnRequest {
        prompt: "prepare report".into(),
        requested_model: None,
    }))
    .expect("start through trait");

    assert_eq!(lifecycle.runtime(), "fake");
    assert_eq!(
        ready(lifecycle.status(&id)).expect("status through trait"),
        AgentTurnStatus::Queued
    );
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
    }))
    .expect("start turn")
}
