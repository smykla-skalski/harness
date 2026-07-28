use super::*;

#[test]
fn run_context_from_run_dir_loads_metadata_and_status() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = tmp.path().join("run-1");
    let layout = RunLayout::from_run_dir(&run_dir);
    layout.ensure_dirs().unwrap();

    let metadata = sample_metadata();
    let meta_json = serde_json::to_string_pretty(&metadata).unwrap();
    fs::write(layout.metadata_path(), &meta_json).unwrap();
    write_run_status_file(&layout, "run-1");

    let ctx = RunContext::from_run_dir(&run_dir).unwrap();
    assert_run_context_identity(&ctx, "run-1");
    assert_run_context_status(&ctx, "run-1");
    assert_run_context_optional_artifacts_absent(&ctx);
}

#[test]
fn run_context_from_run_dir_fails_on_missing_metadata() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = tmp.path().join("run-missing");
    fs::create_dir_all(&run_dir).unwrap();

    let result = RunContext::from_run_dir(&run_dir);
    assert!(result.is_err());
    let err = result.unwrap_err();
    assert_eq!(err.code(), "KSRCLI014");
}

#[test]
fn artifact_snapshot_serialization() {
    let snap = ArtifactSnapshot {
        kind: "markdown".into(),
        exists: true,
        row_count: Some(5),
        files: vec!["a.txt".into(), "b.txt".into()],
    };
    let json = serde_json::to_string(&snap).unwrap();
    let back: ArtifactSnapshot = serde_json::from_str(&json).unwrap();
    assert_eq!(snap, back);
}

#[test]
fn run_context_from_run_dir_fails_on_corrupt_prepared_suite() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = tmp.path().join("run-corrupt");
    let layout = RunLayout::from_run_dir(&run_dir);
    layout.ensure_dirs().unwrap();

    let metadata = sample_metadata();
    fs::write(
        layout.metadata_path(),
        serde_json::to_string_pretty(&metadata).unwrap(),
    )
    .unwrap();
    let status_data = serde_json::json!({
        "run_id": "run-1",
        "suite_id": "suite-a",
        "profile": "single-zone",
        "started_at": "2026-03-14T00:00:00Z",
        "overall_verdict": "pending",
        "notes": []
    });
    fs::write(
        layout.status_path(),
        serde_json::to_string_pretty(&status_data).unwrap(),
    )
    .unwrap();

    fs::write(layout.prepared_suite_path(), "NOT VALID JSON").unwrap();

    let result = RunContext::from_run_dir(&run_dir);
    assert!(
        result.is_err(),
        "expected Err for corrupt prepared-suite, got Ok"
    );
}

#[test]
fn preflight_artifact_deserialization_with_defaults() {
    let data = serde_json::json!({"checked_at": "2026-03-14T00:00:00Z"});
    let artifact: PreflightArtifact = serde_json::from_value(data).unwrap();
    assert_eq!(artifact.checked_at, "2026-03-14T00:00:00Z");
    assert!(artifact.prepared_suite_path.is_none());
    assert!(artifact.repo_root.is_none());
    assert!(artifact.tools.items.is_empty());
    assert!(artifact.nodes.items.is_empty());
}

#[test]
fn run_context_loads_cluster_from_state_dir() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = tmp.path().join("run-cluster");
    let layout = RunLayout::from_run_dir(&run_dir);
    layout.ensure_dirs().unwrap();

    let metadata = sample_metadata();
    fs::write(
        layout.metadata_path(),
        serde_json::to_string_pretty(&metadata).unwrap(),
    )
    .unwrap();
    let status_data = serde_json::json!({
        "run_id": "run-1",
        "suite_id": "suite-a",
        "profile": "single-zone",
        "started_at": "2026-03-14T00:00:00Z",
        "overall_verdict": "pending",
        "notes": []
    });
    fs::write(
        layout.status_path(),
        serde_json::to_string_pretty(&status_data).unwrap(),
    )
    .unwrap();

    let mut spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/r",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    spec.admin_token = Some("test-token-abc".into());
    spec.members[0].container_ip = Some("172.57.0.2".into());
    fs::write(
        layout.state_dir().join("cluster.json"),
        serde_json::to_string_pretty(&spec).unwrap(),
    )
    .unwrap();

    let ctx = RunContext::from_run_dir(&run_dir).unwrap();
    let cluster = ctx.cluster.unwrap();
    assert_eq!(cluster.platform, Platform::Universal);
    assert_eq!(cluster.admin_token.as_deref(), Some("test-token-abc"));
    assert_eq!(
        cluster.members[0].container_ip.as_deref(),
        Some("172.57.0.2")
    );
}
