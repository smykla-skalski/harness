use super::validate_completed_artifact;
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionPhase, TaskBoardImplementationResult,
};

#[test]
fn dependency_triage_action_rejects_implementation_artifact() {
    let attempt = TaskBoardExecutionAttemptRecord {
        execution_id: "execution-a".into(),
        action_key: "dependency_triage".into(),
        attempt: 1,
        idempotency_key: "triage-a".into(),
        state: TaskBoardAttemptState::Completed,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: Some(TaskBoardAttemptResultArtifact::Implementation(
            TaskBoardImplementationResult {
                revision_cycle: 1,
                base_head_revision: "head-base".into(),
                head_revision: "head-updated".into(),
                summary: "wrong artifact".into(),
                evidence: Vec::new(),
            },
        )),
        started_at: "2026-07-30T18:00:00Z".into(),
        updated_at: "2026-07-30T18:01:00Z".into(),
        completed_at: Some("2026-07-30T18:01:00Z".into()),
    };

    let error = validate_completed_artifact(TaskBoardExecutionPhase::Implementation, &attempt)
        .expect_err("action and artifact kind must agree");
    assert!(error.to_string().contains("contradicts its frozen phase"));
}
