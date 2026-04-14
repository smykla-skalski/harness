use std::fs;

use harness::run::RecordArgs;
use harness::run::RunDirArgs;

use super::super::super::helpers::*;
use super::txt_artifact_paths;

#[test]
fn record_accepts_run_dir_phase_and_label() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-1", "single-zone");
    let args = RunDirArgs {
        run_dir: Some(run_dir.clone()),
        run_id: None,
        run_root: None,
    };

    let result = record_cmd(RecordArgs {
        repo_root: None,
        phase: Some("verify".into()),
        label: Some("test".into()),
        gid: None,
        cluster: None,
        command: vec!["echo".into(), "hello".into()],
        run_dir: args,
    })
    .execute();
    assert!(result.is_ok(), "record should succeed: {result:?}");

    let artifacts = txt_artifact_paths(&run_dir.join("commands"));
    assert!(
        !artifacts.is_empty(),
        "should create at least one artifact file"
    );

    let cmd_log = run_dir.join("commands").join("command-log.md");
    assert!(cmd_log.exists(), "command-log.md should exist");
    let log_text = fs::read_to_string(&cmd_log).unwrap();
    assert!(log_text.contains("echo"), "log should contain the command");
}

#[test]
fn record_exports_context_env() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-env", "single-zone");
    let args = RunDirArgs {
        run_dir: Some(run_dir.clone()),
        run_id: None,
        run_root: None,
    };

    let result = record_cmd(RecordArgs {
        repo_root: None,
        phase: Some("verify".into()),
        label: Some("env-check".into()),
        gid: None,
        cluster: None,
        command: vec!["env".into()],
        run_dir: args,
    })
    .execute();
    assert!(result.is_ok(), "record env should succeed: {result:?}");

    let artifacts = txt_artifact_paths(&run_dir.join("commands"));
    assert!(!artifacts.is_empty(), "artifact should exist");

    let content = fs::read_to_string(&artifacts[0]).unwrap();
    assert!(content.contains("PATH"), "env output should contain PATH");
}

#[test]
fn run_can_target_another_tracked_cluster_member() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-cluster-member", "single-zone");
    let args = RunDirArgs {
        run_dir: Some(run_dir),
        run_id: None,
        run_root: None,
    };

    let result = record_cmd(RecordArgs {
        repo_root: None,
        phase: Some("verify".into()),
        label: Some("zone-check".into()),
        gid: None,
        cluster: Some("zone-1".into()),
        command: vec!["echo".into(), "cluster-test".into()],
        run_dir: args,
    })
    .execute();
    assert!(
        result.is_ok(),
        "record with cluster arg should succeed: {result:?}"
    );
}

#[test]
fn record_creates_artifact_even_when_binary_not_found() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-missing-bin", "single-zone");
    let args = RunDirArgs {
        run_dir: Some(run_dir.clone()),
        run_id: None,
        run_root: None,
    };

    let result = record_cmd(RecordArgs {
        repo_root: None,
        phase: Some("verify".into()),
        label: Some("missing".into()),
        gid: None,
        cluster: None,
        command: vec!["nonexistent-binary-xyz-12345".into()],
        run_dir: args,
    })
    .execute();
    assert!(result.is_err(), "missing binary should return error");

    let artifacts = txt_artifact_paths(&run_dir.join("commands"));
    assert!(
        !artifacts.is_empty(),
        "artifact should be created even for missing binary"
    );
}

#[test]
fn record_run_dir_refreshes_current_session_context() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "rec-refresh", "single-zone");
    let args = RunDirArgs {
        run_dir: Some(run_dir),
        run_id: None,
        run_root: None,
    };

    let result = record_cmd(RecordArgs {
        repo_root: None,
        phase: Some("verify".into()),
        label: Some("refresh".into()),
        gid: None,
        cluster: None,
        command: vec!["echo".into(), "refresh-test".into()],
        run_dir: args,
    })
    .execute();
    assert!(
        result.is_ok(),
        "record with --run-dir should succeed: {result:?}"
    );
}

#[test]
fn run_uses_active_project_run_without_explicit_run_id() {
    let args = RunDirArgs {
        run_dir: None,
        run_id: None,
        run_root: None,
    };

    let result = record_cmd(RecordArgs {
        repo_root: None,
        phase: Some("verify".into()),
        label: Some("no-id".into()),
        gid: None,
        cluster: None,
        command: vec!["echo".into(), "no-run-id".into()],
        run_dir: args,
    })
    .execute();
    assert!(
        result.is_ok(),
        "record without run-dir should succeed: {result:?}"
    );
}
