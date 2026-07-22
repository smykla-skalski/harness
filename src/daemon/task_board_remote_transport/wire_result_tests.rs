use super::wire::{
    MAX_REMOTE_TYPED_RESULT_BYTES, RemoteAttemptBinding, RemoteTypedResult, RemoteWireError,
};
use super::wire_tests::binding;
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardEvaluationResult, TaskBoardExecutionPhase, TaskBoardImplementationResult,
    TaskBoardLocalAttemptResult, TaskBoardPhaseVerdict, TaskBoardReviewResult,
    TaskBoardReviewerOutcome,
};

const BASE: &str = "1111111111111111111111111111111111111111";
const HEAD: &str = "2222222222222222222222222222222222222222";

#[test]
fn typed_result_accepts_exact_serialized_limit_and_rejects_one_more_byte() {
    let binding = implementation_binding();
    let mut empty = implementation_result(&binding);
    let TaskBoardAttemptResultArtifact::Implementation(artifact) = &mut empty.artifact else {
        unreachable!("implementation result")
    };
    artifact.summary.clear();
    let probe = RemoteTypedResult {
        offer_request_sha256: "c".repeat(64),
        result: empty,
        result_sha256: "d".repeat(64),
    };
    let fixed_bytes = serde_json::to_vec(&probe)
        .expect("serialize result probe")
        .len();
    let mut exact = probe;
    let TaskBoardAttemptResultArtifact::Implementation(artifact) = &mut exact.result.artifact
    else {
        unreachable!("implementation result")
    };
    artifact.summary = "x".repeat(MAX_REMOTE_TYPED_RESULT_BYTES - fixed_bytes);
    assert_eq!(
        serde_json::to_vec(&exact)
            .expect("serialize exact result")
            .len(),
        MAX_REMOTE_TYPED_RESULT_BYTES
    );
    exact
        .validate_serialized_size()
        .expect("exact result size is accepted");

    let TaskBoardAttemptResultArtifact::Implementation(artifact) = &mut exact.result.artifact
    else {
        unreachable!("implementation result")
    };
    artifact.summary.push('x');
    assert_eq!(
        exact.validate_serialized_size(),
        Err(RemoteWireError::ResultTooLarge)
    );
    assert_eq!(
        RemoteTypedResult::seal(exact.result, "c".repeat(64)),
        Err(RemoteWireError::ResultTooLarge)
    );
}

#[test]
fn implementation_result_rejects_wrong_schema_head_and_base() {
    let binding = implementation_binding();
    let valid = implementation_result(&binding);
    assert_valid(&binding, valid.clone());

    let mut wrong_schema = valid.clone();
    wrong_schema.schema_version += 1;
    assert_invalid(&binding, wrong_schema);

    let mut wrong_head = valid.clone();
    wrong_head.exact_head_revision = "3333333333333333333333333333333333333333".into();
    assert_invalid(&binding, wrong_head);

    let mut wrong_base = valid;
    let TaskBoardAttemptResultArtifact::Implementation(artifact) = &mut wrong_base.artifact else {
        unreachable!("implementation result")
    };
    artifact.base_head_revision = "3333333333333333333333333333333333333333".into();
    assert_invalid(&binding, wrong_base);
}

#[test]
fn implementation_result_rejects_wrong_cycle_action_and_summary() {
    let binding = implementation_binding();
    let valid = implementation_result(&binding);

    let mut wrong_cycle = valid.clone();
    let TaskBoardAttemptResultArtifact::Implementation(artifact) = &mut wrong_cycle.artifact else {
        unreachable!("implementation result")
    };
    artifact.revision_cycle = 2;
    assert_invalid(&binding, wrong_cycle);

    let mut wrong_action = valid.clone();
    wrong_action.action_key = "implementation:2".into();
    assert_invalid(&binding, wrong_action);

    let mut padded_summary = valid;
    let TaskBoardAttemptResultArtifact::Implementation(artifact) = &mut padded_summary.artifact
    else {
        unreachable!("implementation result")
    };
    artifact.summary = " implemented ".into();
    assert_invalid(&binding, padded_summary);
}

#[test]
fn review_result_binds_phase_action_profile_and_head() {
    let binding = review_binding();
    let valid = review_result(&binding);
    assert_valid(&binding, valid.clone());

    let mut wrong_profile = valid.clone();
    let TaskBoardAttemptResultArtifact::Review(artifact) = &mut wrong_profile.artifact else {
        unreachable!("review result")
    };
    artifact.profile_id = "other-reviewer".into();
    assert_invalid(&binding, wrong_profile);

    let mut wrong_head = valid.clone();
    let TaskBoardAttemptResultArtifact::Review(artifact) = &mut wrong_head.artifact else {
        unreachable!("review result")
    };
    artifact.result.head_revision = BASE.into();
    assert_invalid(&binding, wrong_head);

    let mut wrong_phase_artifact = valid;
    wrong_phase_artifact.artifact = evaluation_artifact(Some(1), Some(HEAD));
    assert_invalid(&binding, wrong_phase_artifact);
}

#[test]
fn write_evaluation_result_binds_action_cycle_and_head() {
    let binding = evaluation_binding();
    let valid = evaluation_result(&binding, Some(1), Some(HEAD));
    assert_valid(&binding, valid.clone());

    let mut wrong_cycle = valid.clone();
    let TaskBoardAttemptResultArtifact::Evaluation(artifact) = &mut wrong_cycle.artifact else {
        unreachable!("evaluation result")
    };
    artifact.revision_cycle = Some(2);
    assert_invalid(&binding, wrong_cycle);

    let mut wrong_head = valid.clone();
    let TaskBoardAttemptResultArtifact::Evaluation(artifact) = &mut wrong_head.artifact else {
        unreachable!("evaluation result")
    };
    artifact.head_revision = Some(BASE.into());
    assert_invalid(&binding, wrong_head);

    let mut wrong_action = valid;
    wrong_action.action_key = "evaluate:2".into();
    assert_invalid(&binding, wrong_action);
}

fn implementation_binding() -> RemoteAttemptBinding {
    RemoteAttemptBinding {
        action_key: "implementation:1".into(),
        expected_head_revision: None,
        ..binding()
    }
}

fn review_binding() -> RemoteAttemptBinding {
    RemoteAttemptBinding {
        phase: TaskBoardExecutionPhase::Review,
        action_key: "review:reviewer".into(),
        base_revision: HEAD.into(),
        expected_head_revision: Some(HEAD.into()),
        ..binding()
    }
}

fn evaluation_binding() -> RemoteAttemptBinding {
    RemoteAttemptBinding {
        phase: TaskBoardExecutionPhase::Evaluate,
        action_key: "evaluate:1".into(),
        base_revision: HEAD.into(),
        expected_head_revision: Some(HEAD.into()),
        ..binding()
    }
}

fn implementation_result(binding: &RemoteAttemptBinding) -> TaskBoardLocalAttemptResult {
    TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: binding.execution_id.clone(),
        action_key: binding.action_key.clone(),
        attempt: binding.attempt,
        idempotency_key: binding.idempotency_key.clone(),
        exact_head_revision: HEAD.into(),
        artifact: TaskBoardAttemptResultArtifact::Implementation(TaskBoardImplementationResult {
            revision_cycle: 1,
            base_head_revision: BASE.into(),
            head_revision: HEAD.into(),
            summary: "implemented".into(),
            evidence: Vec::new(),
        }),
    }
}

fn review_result(binding: &RemoteAttemptBinding) -> TaskBoardLocalAttemptResult {
    TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: binding.execution_id.clone(),
        action_key: binding.action_key.clone(),
        attempt: binding.attempt,
        idempotency_key: binding.idempotency_key.clone(),
        exact_head_revision: HEAD.into(),
        artifact: TaskBoardAttemptResultArtifact::Review(TaskBoardReviewerOutcome {
            profile_id: "reviewer".into(),
            result: TaskBoardReviewResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                head_revision: HEAD.into(),
                summary: "reviewed".into(),
                findings: Vec::new(),
            },
        }),
    }
}

fn evaluation_result(
    binding: &RemoteAttemptBinding,
    cycle: Option<u32>,
    head: Option<&str>,
) -> TaskBoardLocalAttemptResult {
    TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: binding.execution_id.clone(),
        action_key: binding.action_key.clone(),
        attempt: binding.attempt,
        idempotency_key: binding.idempotency_key.clone(),
        exact_head_revision: HEAD.into(),
        artifact: evaluation_artifact(cycle, head),
    }
}

fn evaluation_artifact(cycle: Option<u32>, head: Option<&str>) -> TaskBoardAttemptResultArtifact {
    TaskBoardAttemptResultArtifact::Evaluation(TaskBoardEvaluationResult {
        verdict: TaskBoardPhaseVerdict::Pass,
        summary: "evaluated".into(),
        evidence: Vec::new(),
        head_revision: head.map(str::to_owned),
        revision_cycle: cycle,
    })
}

fn assert_valid(binding: &RemoteAttemptBinding, result: TaskBoardLocalAttemptResult) {
    RemoteTypedResult::seal(result, "c".repeat(64))
        .expect("seal typed result")
        .validate(binding, &"c".repeat(64))
        .expect("valid typed result");
}

fn assert_invalid(binding: &RemoteAttemptBinding, result: TaskBoardLocalAttemptResult) {
    assert_eq!(
        RemoteTypedResult::seal(result, "c".repeat(64))
            .expect("seal typed result")
            .validate(binding, &"c".repeat(64))
            .expect_err("invalid result denied"),
        RemoteWireError::ResultBindingMismatch
    );
}
