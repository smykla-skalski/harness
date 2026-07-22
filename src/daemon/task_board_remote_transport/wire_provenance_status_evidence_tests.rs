use super::*;

#[test]
fn status_run_evidence_is_paired_opaque_and_digest_bound() {
    let offer = offer_request().seal().expect("seal offer");
    let request = status_request(&offer);
    let response = RemoteStatusResponse {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding,
        state: RemoteAssignmentWireState::Running,
        offer_request_sha256: offer.request_sha256,
        status_sha256: String::new(),
        lease: Some(lease()),
        result: None,
        output_artifacts: RemoteArtifactManifest::default(),
        claimed_at: Some("2026-07-19T12:00:30Z".into()),
        started_at: Some("2026-07-19T12:01:00Z".into()),
        workspace_ref: Some("workspace-assignment-1".into()),
        error_code: None,
        failure_class: None,
        observed_at: "2026-07-19T12:02:00Z".into(),
    }
    .seal()
    .expect("seal running status");
    response.validate(&request).expect("valid run evidence");
    let restored: RemoteStatusResponse = serde_json::from_slice(
        &serde_json::to_vec(&response).expect("serialize durable host status"),
    )
    .expect("restore durable host status");
    assert_eq!(restored.workspace_ref, response.workspace_ref);
    restored
        .validate(&request)
        .expect("restored host run evidence");

    let mut partial = response.clone();
    partial.workspace_ref = None;
    assert_eq!(
        partial
            .validate(&request)
            .expect_err("partial evidence denied"),
        RemoteWireError::ResultBindingMismatch
    );
    let mut path = response.clone();
    path.workspace_ref = Some("/tmp/controller-worktree".into());
    assert_eq!(
        path.validate(&request).expect_err("local path denied"),
        RemoteWireError::InvalidWorkspaceReference
    );
    let mut noncanonical = response.clone();
    noncanonical.started_at = Some("2026-07-19T14:01:00+02:00".into());
    assert_eq!(
        noncanonical
            .validate(&request)
            .expect_err("noncanonical start denied"),
        RemoteWireError::InvalidTimestamp("started_at")
    );
    let mut tampered = response;
    tampered.workspace_ref = Some("workspace-assignment-2".into());
    assert_eq!(
        tampered
            .validate(&request)
            .expect_err("workspace replay denied"),
        RemoteWireError::DigestMismatch("status_sha256")
    );
}
