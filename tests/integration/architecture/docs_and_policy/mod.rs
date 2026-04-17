use std::path::Path;

use super::helpers::{
    assert_file_lacks_needles, collect_hits_in_paths, collect_hits_in_tree, read_repo_file,
};

mod policy_rules;
mod version_sync;

#[test]
fn setup_does_not_mutate_run_repository_directly() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hits = collect_hits_in_tree(
        &root.join("src/setup"),
        root,
        None,
        &[
            "RunRepository",
            "current_pointer_path(",
            "RunLayout::current_pointer",
            "write_json_pretty(",
        ],
        |path, needle| format!("{path} still reaches into run-owned persistence via `{needle}`"),
    );

    assert!(
        hits.is_empty(),
        "setup should go through run application helpers for current-run persistence:\n{}",
        hits.join("\n")
    );
}

#[test]
fn setup_session_transport_stays_transport_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let session_mod = read_repo_file(root, "src/setup/session.rs");
    assert_file_lacks_needles(
        &session_mod,
        "src/setup/session.rs should stay transport-only instead of owning",
        &[
            "wrapper::main(",
            "pending_compact_handoff(",
            "render_hydration_context(",
            "consume_compact_handoff(",
            "RunApplication::current_run_dir(",
            "RunApplication::clear_current_pointer(",
        ],
    );

    let service = read_repo_file(root, "src/setup/services/session.rs");
    super::helpers::assert_file_contains_needles(
        &service,
        "src/setup/services/session.rs should own",
        &[
            "fn bootstrap_project_wrapper(",
            "fn restore_compact_handoff(",
            "fn cleanup_current_run_context(",
        ],
    );
}

#[test]
fn setup_wrapper_does_not_depend_on_block_registry() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hits = collect_hits_in_tree(
        &root.join("src/setup/wrapper"),
        root,
        None,
        &["BlockRegistry"],
        |path, _| format!("{path} should use pure runner policy data instead of BlockRegistry"),
    );
    assert!(hits.is_empty(), "{}", hits.join("\n"));
}

#[test]
fn infra_blocks_do_not_export_legacy_block_registry() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let blocks_mod = read_repo_file(root, "src/infra/blocks/mod.rs");
    let registry = read_repo_file(root, "src/infra/blocks/registry.rs");

    assert!(
        !blocks_mod.contains("BlockRegistry"),
        "src/infra/blocks/mod.rs should not export the retired BlockRegistry"
    );
    assert!(
        !registry.contains("pub struct BlockRegistry"),
        "src/infra/blocks/registry.rs should keep only block requirement policy, not a global registry"
    );
}

#[test]
fn tool_fact_model_is_owned_by_kernel() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hooks_context = read_repo_file(root, "src/hooks/protocol/context.rs");
    assert_file_lacks_needles(
        &hooks_context,
        "src/hooks/protocol/context.rs should consume kernel::tooling instead of redefining",
        &[
            "pub enum ToolCategory",
            "pub enum ToolInput",
            "pub struct ToolContext",
            "fn normalize_tool_input",
        ],
    );

    let kernel_tooling = read_repo_file(root, "src/kernel/tooling.rs");
    assert!(
        kernel_tooling.contains("pub struct ToolContext"),
        "src/kernel/tooling.rs should own the shared tool fact model"
    );
}

#[test]
fn kuma_contracts_are_isolated_to_block_namespace() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hits = collect_hits_in_tree(
        &root.join("src"),
        root,
        Some(&root.join("src/infra/blocks/kuma")),
        &[
            "Kuma test harness",
            "~kuma",
            ".join(\"kuma\")",
            "`harness cluster`",
            "harness cluster ",
            "`harness token`",
            "harness token ",
            "`harness service`",
            "harness service ",
            "`harness api`",
            "harness api ",
            "`harness kumactl`",
            "harness kumactl ",
        ],
        |path, needle| format!("{path} contains forbidden Kuma contract `{needle}`"),
    );

    assert!(
        hits.is_empty(),
        "found Kuma contract leaks outside src/infra/blocks/kuma:\n{}",
        hits.join("\n")
    );
}

#[test]
fn docs_do_not_reference_legacy_kuma_storage_paths() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let readme = read_repo_file(root, "README.md");
    assert_file_lacks_needles(
        &readme,
        "README.md should not reference legacy Kuma storage paths via",
        &["$XDG_DATA_HOME/kuma", ".local/share/kuma"],
    );
}

#[test]
fn monitor_and_daemon_logging_defaults_stay_production_safe() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let app_info = read_repo_file(
        root,
        "apps/harness-monitor-macos/Resources/HarnessMonitor-Info.plist",
    );
    let launch_agent = read_repo_file(
        root,
        "apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.plist",
    );
    let agents = read_repo_file(root, "AGENTS.md");
    let claude = read_repo_file(root, "CLAUDE.md");

    assert!(
        app_info.contains("<key>OSLogPreferences</key>")
            && app_info.contains("<string>Debug</string>"),
        "Harness Monitor app Info.plist should keep OSLogPreferences at Debug persistence/enabling for investigation-grade logging"
    );
    assert!(
        launch_agent.contains("<key>RUST_LOG</key>")
            && launch_agent.contains("<string>harness=info</string>"),
        "bundled launch agent should pin the daemon default filter to harness=info"
    );
    assert!(
        agents.contains("Default filter: `RUST_LOG=harness=info`"),
        "AGENTS.md should document the info default filter"
    );
    assert!(
        claude.contains("Default filter: `RUST_LOG=harness=info`"),
        "CLAUDE.md should document the info default filter"
    );
}

#[test]
fn repo_contains_no_legacy_grouped_lifecycle_commands() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let session_start = ["harness", " setup", " session-start"].concat();
    let session_stop = ["harness", " setup", " session-stop"].concat();
    let pre_compact = ["harness", " setup", " pre-compact"].concat();
    let needles = [
        session_start.as_str(),
        session_stop.as_str(),
        pre_compact.as_str(),
    ];
    let mut hits = Vec::new();

    for start in [root.join("src"), root.join("tests")] {
        hits.extend(collect_hits_in_tree(
            &start,
            root,
            None,
            &needles,
            |path, needle| {
                format!("{path} still contains legacy grouped lifecycle command `{needle}`")
            },
        ));
    }

    hits.extend(collect_hits_in_paths(
        root,
        &[
            ".claude/plugins/suite/hooks/hooks.json",
            "README.md",
            "ARCHITECTURE.md",
        ],
        &needles,
        |path, needle| format!("{path} still contains legacy grouped lifecycle command `{needle}`"),
    ));

    assert!(
        hits.is_empty(),
        "found legacy grouped lifecycle commands:\n{}",
        hits.join("\n")
    );
}

#[test]
fn repo_contains_no_legacy_public_create_skill_flags() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let begin = ["harness", " create", " begin", " --skill", " suite:create"].concat();
    let approval = [
        "harness",
        " create",
        " approval-begin",
        " --skill",
        " suite:create",
    ]
    .concat();
    let reset = ["harness", " create", " reset", " --skill", " suite:create"].concat();
    let needles = [begin.as_str(), approval.as_str(), reset.as_str()];
    let mut hits = Vec::new();

    for start in [root.join("src"), root.join("tests")] {
        hits.extend(collect_hits_in_tree(
            &start,
            root,
            None,
            &needles,
            |path, needle| {
                format!("{path} still contains legacy public create flag contract `{needle}`")
            },
        ));
    }

    hits.extend(collect_hits_in_paths(
        root,
        &[
            ".claude/plugins/suite/skills/create/SKILL.md",
            ".claude/plugins/suite/skills/create/references/operational-guide.md",
            "README.md",
            "ARCHITECTURE.md",
        ],
        &needles,
        |path, needle| {
            format!("{path} still contains legacy public create flag contract `{needle}`")
        },
    ));

    assert!(
        hits.is_empty(),
        "found legacy public create skill flags:\n{}",
        hits.join("\n")
    );
}

#[test]
fn repo_contains_no_legacy_observe_doctor_scan_action() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let doctor = [
        "harness",
        " observe",
        " scan",
        " <session-id>",
        " --action",
        " doctor",
    ]
    .concat();
    let needles = [doctor.as_str()];
    let mut hits = Vec::new();

    for start in [root.join("src"), root.join("tests")] {
        hits.extend(collect_hits_in_tree(
            &start,
            root,
            None,
            &needles,
            |path, needle| {
                format!("{path} still contains legacy observe doctor action contract `{needle}`")
            },
        ));
    }

    hits.extend(collect_hits_in_paths(
        root,
        &[
            ".claude/plugins/observe/skills/observe/SKILL.md",
            ".claude/plugins/observe/skills/observe/references/command-surface.md",
            "README.md",
            "ARCHITECTURE.md",
        ],
        &needles,
        |path, needle| {
            format!("{path} still contains legacy observe doctor action contract `{needle}`")
        },
    ));

    assert!(
        hits.is_empty(),
        "found legacy observe doctor action contract:\n{}",
        hits.join("\n")
    );
}

#[test]
fn canonical_observe_sources_avoid_host_owned_runtime_paths() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let needles = [
        "$XDG_DATA_HOME/harness/observe/<SESSION_ID>.state",
        ".claude/plugins/suite/skills/",
        "~/.claude/projects/",
        "~/.Codex/projects/",
    ];
    let hits = collect_hits_in_paths(
        root,
        &[
            "agents/skills/observe/body.md",
            "agents/skills/observe/agents/deep-analyst.md",
            "agents/skills/observe/references/issue-taxonomy.md",
            "agents/skills/observe/references/overrides.md",
        ],
        &needles,
        |path, needle| {
            format!("{path} still contains host-owned observe source-of-truth path `{needle}`")
        },
    );

    assert!(
        hits.is_empty(),
        "canonical observe sources still reference host-owned paths:\n{}",
        hits.join("\n")
    );
}

#[test]
fn shared_plugin_outputs_stay_portable() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hits = collect_hits_in_paths(
        root,
        &[
            "plugins/suite/skills/create/SKILL.md",
            "plugins/suite/skills/run/SKILL.md",
        ],
        &[
            "--agent codex",
            "--agent copilot",
            "matcher: AskUserQuestion",
        ],
        |path, needle| {
            format!("{path} still contains host-specific shared-plugin content `{needle}`")
        },
    );

    assert!(
        hits.is_empty(),
        "shared plugin outputs are still host-specific:\n{}",
        hits.join("\n")
    );
}
