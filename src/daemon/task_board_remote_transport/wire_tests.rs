use sha2::{Digest, Sha256};

use super::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteAttemptBinding, RemoteCancelRequest,
    RemoteClaimRequest, RemoteHeartbeatRequest, RemoteLeaseRenewRequest, RemoteOfferDisposition,
    RemoteOfferRequest, RemoteOfferResponse, RemoteSettledRequest, RemoteSourceMaterial,
    RemoteTypedResult, RemoteWireError, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION, test_codex_launch,
};
use crate::task_board::{
    TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardEvaluationResult, TaskBoardExecutionPhase, TaskBoardLocalAttemptResult,
    TaskBoardPhaseVerdict, TaskBoardWorkflowKind,
};

#[test]
fn sealed_offer_digest_binds_complete_attempt_and_repository_evidence() {
    let request = offer_request().seal().expect("seal offer");
    request.validate().expect("sealed request");

    let mut variants = Vec::new();
    variants.push(with_binding(&request, |binding| {
        binding.assignment_id = "other".into()
    }));
    let mut execution_changed = request.clone();
    execution_changed.binding.execution_id = "other".into();
    execution_changed.launch = test_codex_launch(
        TaskBoardExecutionPhase::Implementation,
        "other",
        "evaluate:1",
        "Implement the frozen task plan.",
    );
    variants.push(execution_changed);
    variants.push(with_binding(&request, |binding| {
        binding.action_key = "other".into()
    }));
    variants.push(with_binding(&request, |binding| binding.attempt = 2));
    variants.push(with_binding(&request, |binding| {
        binding.idempotency_key = "other".into()
    }));
    variants.push(with_binding(&request, |binding| {
        binding.host_instance_id = "other".into()
    }));
    variants.push(with_binding(&request, |binding| binding.fencing_epoch = 2));
    variants.push(with_binding(&request, |binding| {
        binding.configuration_revision = 2
    }));
    variants.push(with_binding(&request, |binding| {
        binding.execution_record_sha256 = "b".repeat(64);
    }));
    let mut repository_changed = with_binding(&request, |binding| {
        binding.repository = "org/other".into()
    });
    repository_changed.source = RemoteSourceMaterial::repository_revision(
        "org/other",
        "1111111111111111111111111111111111111111",
    );
    variants.push(repository_changed);
    variants.push(with_binding(&request, |binding| {
        binding.base_revision = "3333333333333333333333333333333333333333".into()
    }));
    let mut workflow_kind_changed = with_binding(&request, |binding| {
        binding.workflow_kind = TaskBoardWorkflowKind::PrFix;
    });
    workflow_kind_changed.source = RemoteSourceMaterial::repository_branch(
        &request.binding.repository,
        "feature/review",
        "1111111111111111111111111111111111111111",
    );
    variants.push(workflow_kind_changed);
    let mut deadline_changed = request.clone();
    deadline_changed.deadline_at = "2026-07-19T12:11:00Z".into();
    variants.push(deadline_changed);
    for variant in variants {
        assert_eq!(
            variant.validate().expect_err("tampered offer denied"),
            RemoteWireError::DigestMismatch("request_sha256")
        );
    }
}

#[test]
fn offer_deadline_is_absolute_canonical_and_digest_bound() {
    let mut request = offer_request();
    request.deadline_at = "2026-07-19T14:10:00+02:00".into();
    let request = request.seal().expect("seal offer");
    assert_eq!(
        request
            .validate()
            .expect_err("noncanonical deadline denied"),
        RemoteWireError::InvalidTimestamp("deadline_at")
    );
}

#[test]
fn private_envelopes_reject_unknown_fields_and_unsupported_versions() {
    let request = offer_request().seal().expect("seal offer");
    let mut json = serde_json::to_value(&request).expect("serialize offer");
    json.as_object_mut()
        .expect("offer object")
        .insert("future_field".into(), serde_json::json!(true));
    assert!(serde_json::from_value::<RemoteOfferRequest>(json).is_err());

    let mut wrong_version = request;
    wrong_version.schema_version += 1;
    assert_eq!(
        wrong_version.validate().expect_err("unsupported version"),
        RemoteWireError::UnsupportedVersion
    );
}

#[test]
fn rejected_offer_requires_a_bounded_canonical_reason_token() {
    let request = offer_request().seal().expect("seal offer");
    let response = |code: &str| RemoteOfferResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: request.binding.clone(),
        offer_request_sha256: request.request_sha256.clone(),
        disposition: RemoteOfferDisposition::Rejected,
        lease: None,
        rejection_code: Some(code.into()),
    };
    response("capacity_changed")
        .validate(&request)
        .expect("canonical rejection code");
    for code in ["", "Capacity_changed", "capacity-changed", "host/rejected"] {
        assert_eq!(
            response(code).validate(&request),
            Err(RemoteWireError::InvalidToken("rejection_code"))
        );
    }
    assert_eq!(
        response(&"a".repeat(65)).validate(&request),
        Err(RemoteWireError::InvalidToken("rejection_code"))
    );
}

#[test]
fn every_mutating_request_has_a_sealing_contract() {
    let _ = RemoteHeartbeatRequest::seal;
    let _ = RemoteClaimRequest::seal;
    let _ = RemoteLeaseRenewRequest::seal;
    let _ = RemoteCancelRequest::seal;
    let _ = RemoteSettledRequest::seal;
}

#[test]
fn remote_dispatch_rejects_planning_and_lifecycle_phases() {
    for phase in [
        TaskBoardExecutionPhase::Planning,
        TaskBoardExecutionPhase::AwaitingApproval,
        TaskBoardExecutionPhase::Publish,
        TaskBoardExecutionPhase::Cleanup,
        TaskBoardExecutionPhase::Terminal,
    ] {
        let mut request = offer_request();
        request.binding.phase = phase;
        let request = request
            .seal()
            .expect("seal structurally serializable offer");
        assert_eq!(
            request.validate().expect_err("non-worker phase denied"),
            RemoteWireError::InvalidPhase
        );
    }
}

#[test]
fn artifact_manifest_is_relative_unique_digest_bound_and_bounded() {
    let manifest = RemoteArtifactManifest {
        entries: vec![artifact("result.bundle", b"bundle")],
    };
    manifest.validate().expect("valid manifest");

    for path in ["/absolute", "../escape", "dir/../escape", "dir\\escape"] {
        let invalid = RemoteArtifactManifest {
            entries: vec![artifact(path, b"bundle")],
        };
        assert_eq!(
            invalid.validate().expect_err("invalid artifact path"),
            RemoteWireError::InvalidManifest
        );
    }
    let duplicate = RemoteArtifactManifest {
        entries: vec![artifact("same", b"one"), artifact("same", b"two")],
    };
    assert_eq!(
        duplicate.validate().expect_err("duplicate artifact"),
        RemoteWireError::InvalidManifest
    );
}

#[test]
fn typed_result_digest_and_exact_head_are_bound_to_attempt() {
    let binding = RemoteAttemptBinding {
        phase: TaskBoardExecutionPhase::Evaluate,
        action_key: "evaluate:1".into(),
        expected_head_revision: Some("2222222222222222222222222222222222222222".into()),
        ..binding()
    };
    let offer_sha = "c".repeat(64);
    let result =
        RemoteTypedResult::seal(
            local_result("2222222222222222222222222222222222222222"),
            offer_sha.clone(),
        )
        .expect("seal result");
    result
        .validate(&binding, &offer_sha)
        .expect("matching typed result");

    let mut wrong_head = result.clone();
    wrong_head.result.exact_head_revision = "3333333333333333333333333333333333333333".into();
    wrong_head =
        RemoteTypedResult::seal(wrong_head.result, offer_sha.clone()).expect("reseal wrong head");
    assert_eq!(
        wrong_head
            .validate(&binding, &offer_sha)
            .expect_err("wrong head denied"),
        RemoteWireError::ResultBindingMismatch
    );

    let mut tampered = result;
    tampered.result_sha256 = "f".repeat(64);
    assert_eq!(
        tampered
            .validate(&binding, &offer_sha)
            .expect_err("tampered digest denied"),
        RemoteWireError::DigestMismatch("result_sha256")
    );
}

pub(super) fn offer_request() -> RemoteOfferRequest {
    RemoteOfferRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: binding(),
        lease_seconds: 60,
        deadline_at: "2026-07-19T12:10:00Z".into(),
        launch: test_codex_launch(
            TaskBoardExecutionPhase::Implementation,
            "execution-1",
            "evaluate:1",
            "Implement the frozen task plan.",
        ),
        source: RemoteSourceMaterial::repository_revision(
            "org/repo",
            "1111111111111111111111111111111111111111",
        ),
        artifacts: RemoteArtifactManifest::default(),
        request_sha256: String::new(),
    }
}

pub(super) fn binding() -> RemoteAttemptBinding {
    RemoteAttemptBinding {
        assignment_id: "assignment-1".into(),
        execution_id: "execution-1".into(),
        phase: TaskBoardExecutionPhase::Implementation,
        workflow_kind: TaskBoardWorkflowKind::DefaultTask,
        action_key: "evaluate:1".into(),
        attempt: 1,
        idempotency_key: "attempt-key".into(),
        host_id: "host-1".into(),
        host_instance_id: "host-instance-1".into(),
        fencing_epoch: 1,
        configuration_revision: 1,
        execution_record_sha256: "a".repeat(64),
        repository: "org/repo".into(),
        base_revision: "1111111111111111111111111111111111111111".into(),
        expected_head_revision: Some("1111111111111111111111111111111111111111".into()),
    }
}

fn with_binding(
    request: &RemoteOfferRequest,
    mutate: impl FnOnce(&mut RemoteAttemptBinding),
) -> RemoteOfferRequest {
    let mut request = request.clone();
    mutate(&mut request.binding);
    request
}

fn local_result(head: &str) -> TaskBoardLocalAttemptResult {
    TaskBoardLocalAttemptResult {
        schema_version: TASK_BOARD_LOCAL_ATTEMPT_RESULT_SCHEMA_VERSION,
        execution_id: "execution-1".into(),
        action_key: "evaluate:1".into(),
        attempt: 1,
        idempotency_key: "attempt-key".into(),
        exact_head_revision: head.into(),
        artifact: TaskBoardAttemptResultArtifact::Evaluation(TaskBoardEvaluationResult {
            verdict: TaskBoardPhaseVerdict::Pass,
            summary: "verified".into(),
            evidence: Vec::new(),
            head_revision: Some(head.into()),
            revision_cycle: Some(1),
        }),
    }
}

pub(super) fn artifact(path: &str, content: &[u8]) -> RemoteArtifactEntry {
    RemoteArtifactEntry {
        relative_path: path.into(),
        sha256: hex::encode(Sha256::digest(content)),
        size_bytes: content.len() as u64,
        media_type: "application/octet-stream".into(),
    }
}
