use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionPhase,
    TaskBoardExecutionState, TaskBoardPhaseVerdict, TaskBoardTerminalOutcomeKind,
};

use super::{
    BASE_HEAD, FIRST_HEAD, FakeWriteRuntime, PlannedRun, RETRY_AT, load_execution,
    seed_write_execution, seed_write_execution_with_retry_limit, tick, tick_at,
};

#[tokio::test]
async fn exhausted_publication_verification_preserves_non_authoritative_mutation_evidence() {
    let fixture =
        seed_write_execution_with_retry_limit("write-publication-verification-exhausted", 1).await;
    let runtime = FakeWriteRuntime::new([
        PlannedRun::implementation(1, 1, BASE_HEAD, FIRST_HEAD),
        PlannedRun::review(1, FIRST_HEAD, TaskBoardPhaseVerdict::Pass),
        PlannedRun::evaluation(1, FIRST_HEAD),
    ]);
    runtime.fail_next_verification("GitHub head is not visible before retry exhaustion");

    for _ in 0..24 {
        tick(&fixture, &runtime).await;
        if load_execution(&fixture).await.transition.execution_state
            == TaskBoardExecutionState::HumanRequired
        {
            break;
        }
    }

    let exhausted = load_execution(&fixture).await;
    assert_eq!(runtime.publish_count(), 1);
    assert_eq!(runtime.verification_count(), 1);
    assert_eq!(
        exhausted.transition.phase,
        Some(TaskBoardExecutionPhase::Publish)
    );
    assert_eq!(
        exhausted.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        exhausted.blocked_reason.as_deref(),
        Some("publish_outcome_unknown")
    );
    assert_eq!(
        exhausted
            .artifacts
            .terminal_outcome
            .as_ref()
            .map(|outcome| outcome.kind),
        Some(TaskBoardTerminalOutcomeKind::Unknown)
    );
    let publish = exhausted
        .attempts
        .iter()
        .find(|attempt| attempt.action_key == "publish")
        .expect("exhausted publish attempt");
    assert_eq!(publish.state, TaskBoardAttemptState::Unknown);
    assert!(publish.artifact.is_none(), "Unknown cannot claim a result");
    let provisional = exhausted
        .artifacts
        .provisional_publication
        .as_ref()
        .expect("durable provisional publication evidence");
    assert!(!provisional.terminal);
    assert!(provisional.mutated);
    assert_eq!(
        provisional.external_url.as_deref(),
        Some("https://github.com/example/compass/pull/42")
    );

    for _ in 0..4 {
        tick(&fixture, &runtime).await;
    }
    assert_eq!(runtime.publish_count(), 1);
    assert_eq!(runtime.verification_count(), 1);
    let reloaded = load_execution(&fixture).await;
    assert_eq!(
        reloaded.artifacts.provisional_publication,
        exhausted.artifacts.provisional_publication
    );
}

#[tokio::test]
async fn permanent_post_publish_verification_failure_preserves_provisional_evidence() {
    let fixture = seed_write_execution("write-publication-verification-rejected").await;
    let runtime = FakeWriteRuntime::new([
        PlannedRun::implementation(1, 1, BASE_HEAD, FIRST_HEAD),
        PlannedRun::review(1, FIRST_HEAD, TaskBoardPhaseVerdict::Pass),
        PlannedRun::evaluation(1, FIRST_HEAD),
    ]);
    runtime.reject_next_verification("authoritative verification rejected the response");

    for _ in 0..24 {
        tick(&fixture, &runtime).await;
        if load_execution(&fixture).await.transition.execution_state
            == TaskBoardExecutionState::HumanRequired
        {
            break;
        }
    }

    let rejected = load_execution(&fixture).await;
    assert_eq!(runtime.publish_count(), 1);
    assert_eq!(runtime.verification_count(), 1);
    let publish = rejected
        .attempts
        .iter()
        .find(|attempt| attempt.action_key == "publish")
        .expect("rejected publish attempt");
    assert_eq!(publish.state, TaskBoardAttemptState::Unknown);
    assert!(publish.artifact.is_none());
    assert_eq!(
        rejected.blocked_reason.as_deref(),
        Some("publish_outcome_unknown")
    );
    assert_eq!(
        rejected
            .artifacts
            .terminal_outcome
            .as_ref()
            .map(|outcome| outcome.kind),
        Some(TaskBoardTerminalOutcomeKind::Unknown)
    );
    let provisional = rejected
        .artifacts
        .provisional_publication
        .as_ref()
        .expect("durable provisional publication evidence");
    assert!(provisional.mutated);
    assert_eq!(
        provisional.external_url.as_deref(),
        Some("https://github.com/example/compass/pull/42")
    );

    for _ in 0..4 {
        tick(&fixture, &runtime).await;
    }
    assert_eq!(runtime.publish_count(), 1);
    assert_eq!(runtime.verification_count(), 1);
}

#[tokio::test]
async fn later_retry_exhaustion_transfers_durable_attempt_evidence() {
    let fixture =
        seed_write_execution_with_retry_limit("write-publication-later-exhaustion", 2).await;
    let runtime = FakeWriteRuntime::new([
        PlannedRun::implementation(1, 1, BASE_HEAD, FIRST_HEAD),
        PlannedRun::review(1, FIRST_HEAD, TaskBoardPhaseVerdict::Pass),
        PlannedRun::evaluation(1, FIRST_HEAD),
    ]);
    runtime.fail_next_verification("GitHub head is not visible on the first check");
    runtime.fail_next_verification("GitHub head is still not visible on retry");

    for _ in 0..24 {
        tick(&fixture, &runtime).await;
        if runtime.verification_count() == 1 {
            break;
        }
    }
    let waiting = load_execution(&fixture).await;
    assert!(waiting.artifacts.provisional_publication.is_none());
    let waiting_publish = waiting
        .attempts
        .iter()
        .find(|attempt| attempt.action_key == "publish")
        .expect("waiting publish attempt");
    assert!(matches!(
        waiting_publish.artifact.as_ref(),
        Some(TaskBoardAttemptResultArtifact::Lifecycle(outcome))
            if outcome.mutated
                && outcome.external_url.as_deref()
                    == Some("https://github.com/example/compass/pull/42")
    ));

    for _ in 0..8 {
        tick_at(&fixture, &runtime, RETRY_AT).await;
        if load_execution(&fixture).await.transition.execution_state
            == TaskBoardExecutionState::HumanRequired
        {
            break;
        }
    }

    let exhausted = load_execution(&fixture).await;
    assert_eq!(runtime.publish_count(), 1);
    assert_eq!(runtime.verification_count(), 2);
    let publish = exhausted
        .attempts
        .iter()
        .find(|attempt| attempt.action_key == "publish")
        .expect("exhausted publish attempt");
    assert_eq!(publish.state, TaskBoardAttemptState::Unknown);
    assert!(publish.artifact.is_none());
    assert_eq!(
        exhausted.blocked_reason.as_deref(),
        Some("publish_outcome_unknown")
    );
    let provisional = exhausted
        .artifacts
        .provisional_publication
        .as_ref()
        .expect("transferred provisional publication evidence");
    assert!(!provisional.terminal);
    assert!(provisional.mutated);
    assert_eq!(
        provisional.external_url.as_deref(),
        Some("https://github.com/example/compass/pull/42")
    );
}
