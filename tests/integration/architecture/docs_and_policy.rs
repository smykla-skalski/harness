use std::path::Path;

use super::helpers::{assert_file_lacks_needles, collect_hits_in_tree, read_repo_file};

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
            "ephemeral_metallb::cleanup_templates(",
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
    let contents = read_repo_file(root, "src/setup/wrapper.rs");
    assert!(
        !contents.contains("BlockRegistry"),
        "src/setup/wrapper.rs should use pure runner policy data instead of BlockRegistry"
    );
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
fn repo_contains_no_clippy_allow_attributes() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let needle = ["allow", "(clippy::"].concat();
    let mut hits = Vec::new();

    for start in [root.join("src"), root.join("tests"), root.join("testkit")] {
        hits.extend(collect_hits_in_tree(
            &start,
            root,
            None,
            &[needle.as_str()],
            |path, matched| format!("{path} still contains forbidden Clippy allow `{matched}`"),
        ));
    }

    assert!(
        hits.is_empty(),
        "found forbidden Clippy allow attributes:\n{}",
        hits.join("\n")
    );
}
