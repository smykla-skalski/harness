use std::fs;

use tempfile::tempdir;

use harness::task_board::{TaskBoardOrchestrator, TaskBoardOrchestratorWorkflow};

#[test]
fn settings_load_rewrites_legacy_dependency_update_workflow_in_place() {
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    fs::create_dir_all(&root).expect("create board root");
    let settings_path = root.join("orchestrator-settings.json");
    fs::write(
        &settings_path,
        r#"{
  "enabled_workflows": [
    "default_task",
    "dependency_update",
    "pr_fix",
    "pr_review"
  ],
  "dry_run_default": true,
  "policy_version": "task-board-policy-v1"
}
"#,
    )
    .expect("seed legacy settings file");

    let orchestrator = TaskBoardOrchestrator::new(root);
    let settings = orchestrator.settings().expect("load migrated settings");

    assert_eq!(
        settings.enabled_workflows,
        vec![
            TaskBoardOrchestratorWorkflow::DefaultTask,
            TaskBoardOrchestratorWorkflow::Review,
            TaskBoardOrchestratorWorkflow::PrFix,
            TaskBoardOrchestratorWorkflow::PrReview,
        ],
        "legacy `dependency_update` must rewrite in place as `review`"
    );

    let on_disk = fs::read_to_string(&settings_path).expect("read rewritten file");
    assert!(
        !on_disk.contains("dependency_update"),
        "legacy variant must be erased from the persisted file, got: {on_disk}"
    );
    assert!(
        on_disk.contains("\"review\""),
        "canonical variant must be persisted, got: {on_disk}"
    );
}

#[test]
fn settings_load_dedupes_when_legacy_and_canonical_workflows_coexist() {
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    fs::create_dir_all(&root).expect("create board root");
    let settings_path = root.join("orchestrator-settings.json");
    fs::write(
        &settings_path,
        r#"{
  "enabled_workflows": [
    "review",
    "dependency_update"
  ],
  "dry_run_default": true,
  "policy_version": "task-board-policy-v1"
}
"#,
    )
    .expect("seed mixed settings file");

    let orchestrator = TaskBoardOrchestrator::new(root);
    let settings = orchestrator.settings().expect("load deduped settings");

    assert_eq!(
        settings.enabled_workflows,
        vec![TaskBoardOrchestratorWorkflow::Review],
        "duplicate canonical entry must collapse to one Review"
    );
}

#[test]
fn settings_load_is_a_noop_when_no_legacy_variants_are_persisted() {
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    fs::create_dir_all(&root).expect("create board root");
    let settings_path = root.join("orchestrator-settings.json");
    let canonical_text = r#"{
  "enabled_workflows": [
    "default_task",
    "review"
  ],
  "dry_run_default": true,
  "policy_version": "task-board-policy-v1"
}
"#;
    fs::write(&settings_path, canonical_text).expect("seed canonical settings file");
    let original_mtime = fs::metadata(&settings_path)
        .and_then(|meta| meta.modified())
        .expect("read original mtime");

    let orchestrator = TaskBoardOrchestrator::new(root);
    let settings = orchestrator.settings().expect("load canonical settings");
    assert_eq!(
        settings.enabled_workflows,
        vec![
            TaskBoardOrchestratorWorkflow::DefaultTask,
            TaskBoardOrchestratorWorkflow::Review,
        ]
    );

    let mtime_after = fs::metadata(&settings_path)
        .and_then(|meta| meta.modified())
        .expect("read settings mtime after load");
    assert_eq!(
        mtime_after, original_mtime,
        "canonical file must not be rewritten on load"
    );
}
