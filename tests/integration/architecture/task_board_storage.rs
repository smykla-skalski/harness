use std::path::Path;

use super::helpers::{collect_hits_in_paths, collect_hits_in_tree};

const LEGACY_FILE_REPOSITORIES: &[(&str, &str)] = &[
    ("src/task_board/store.rs", "pub struct TaskBoardStore"),
    ("src/task_board/machines.rs", "pub struct MachineRegistry"),
    (
        "src/task_board/orchestrator.rs",
        "pub struct TaskBoardOrchestrator",
    ),
    (
        "src/task_board/policy_runtime/repository.rs",
        "pub struct PolicyRuntimeRepository",
    ),
    (
        "src/task_board/policy_runtime/inbox.rs",
        "pub struct PolicyEventInbox",
    ),
    (
        "src/task_board/policy_runtime/handoff_outbox.rs",
        "pub struct PolicyHandoffOutbox",
    ),
    (
        "src/task_board/policy_runtime/notification.rs",
        "pub struct PolicyNotificationOutbox",
    ),
    (
        "src/task_board/policy_runtime/task_creation.rs",
        "pub struct PolicyTaskCreationOutbox",
    ),
];

const FILE_STORAGE_SYMBOLS: &[&str] = &[
    "TaskBoardStore",
    "MachineRegistry",
    "default_board_root",
    "VersionedJsonRepository",
    "orchestrator-settings.json",
    "policy-workflow-runs-v1.json",
];

#[test]
fn task_board_cli_transport_is_daemon_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut hits = collect_hits_in_tree(
        &root.join("src/task_board/transport"),
        root,
        None,
        FILE_STORAGE_SYMBOLS,
        |path, symbol| format!("{path} reaches retired Task Board file storage via `{symbol}`"),
    );
    hits.extend(collect_hits_in_paths(
        root,
        &["src/task_board/transport.rs"],
        FILE_STORAGE_SYMBOLS,
        |path, symbol| format!("{path} reaches retired Task Board file storage via `{symbol}`"),
    ));
    assert!(
        hits.is_empty(),
        "Task Board commands must use the daemon database API only:\n{}",
        hits.join("\n")
    );
}

#[test]
fn live_task_board_consumers_do_not_reopen_legacy_storage() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let paths = [
        "src/daemon/service/task_board_db.rs",
        "src/daemon/service/task_board_orchestrator_db.rs",
        "src/daemon/service/reviews/github_projection.rs",
        "src/daemon/service/reviews.rs",
        "src/daemon/service/reviews/refresh.rs",
        "src/daemon/service/serve/machine_heartbeat_loop.rs",
        "src/daemon/service/serve/task_board_dispatch_loop.rs",
        "src/daemon/service/serve/task_board_orchestrator_loop.rs",
        "src/daemon/http/task_board_route_executor.rs",
        "src/daemon/http/task_board_route_executor/item_ops.rs",
        "src/daemon/http/task_board_route_executor/orchestrator_ops.rs",
        "src/daemon/service/task_board/policy_canvas.rs",
        "src/daemon/service/task_board_runtime.rs",
        "src/daemon/service/task_board_github/support.rs",
        "src/daemon/service/task_board_github/workflow.rs",
    ];
    let mut hits = collect_hits_in_paths(root, &paths, FILE_STORAGE_SYMBOLS, |path, symbol| {
        format!("{path} reaches retired Task Board file storage via `{symbol}`")
    });
    for tree in [
        "src/daemon/client",
        "src/daemon/http",
        "src/daemon/websocket",
        "src/mcp/tools/task_board",
    ] {
        hits.extend(collect_hits_in_tree(
            &root.join(tree),
            root,
            None,
            FILE_STORAGE_SYMBOLS,
            |path, symbol| format!("{path} reaches retired Task Board file storage via `{symbol}`"),
        ));
    }
    assert!(
        hits.is_empty(),
        "live Task Board consumers must use AsyncDaemonDb only:\n{}",
        hits.join("\n")
    );
}

#[test]
fn legacy_task_board_file_repositories_are_test_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    for (relative_path, declaration) in LEGACY_FILE_REPOSITORIES {
        let source = std::fs::read_to_string(root.join(relative_path))
            .unwrap_or_else(|error| panic!("read {relative_path}: {error}"));
        let test_only_declaration = format!("#[cfg(test)]\n{declaration}");
        assert!(
            source.contains(&test_only_declaration),
            "{relative_path} must keep `{declaration}` test-only"
        );
    }
}
