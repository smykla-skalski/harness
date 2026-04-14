use std::fs;
use std::path::Path;

use super::assert_split_modules_exist;

#[test]
fn observe_tool_checks_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let tool_checks_mod =
        fs::read_to_string(root.join("src/observe/classifier/tool_checks/mod.rs")).unwrap();

    for needle in [
        "fn check_bash_tool_use(",
        "fn check_ask_user_question(",
        "fn check_destructive_patterns(",
        "fn check_validator_install_prompt(",
        "const VERIFICATION_KEYWORDS:",
        "const KUBECTL_QUERY_WINDOW:",
    ] {
        assert!(
            !tool_checks_mod.contains(needle),
            "src/observe/classifier/tool_checks/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/observe/classifier/tool_checks/bash.rs",
        "src/observe/classifier/tool_checks/questions.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "observe tool-check split module should exist: {path}"
        );
    }
}

#[test]
fn observe_maintenance_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let maintenance =
        fs::read_to_string(root.join("src/observe/application/maintenance.rs")).unwrap();

    for needle in [
        "struct RecentCycle {",
        "struct ActiveWorkerView<'a> {",
        "struct ObserverStatus<'a> {",
        "struct IssueVerification {",
        "struct ResolveStartResult {",
        "fn render_json<T: Serialize>(",
        "fn render_pretty_json<T: Serialize>(",
        "fn state_file_path(",
        "fn execute_cycle(",
        "fn execute_status(",
        "fn execute_verify(",
        "fn execute_resolve_start(",
        "fn execute_list_categories(",
        "fn execute_list_focus_presets(",
        "fn execute_mute(",
        "fn execute_unmute(",
    ] {
        assert!(
            !maintenance.contains(needle),
            "src/observe/application/maintenance.rs should stay focused on delegation instead of owning `{needle}`"
        );
    }

    for path in [
        "src/observe/application/maintenance/render.rs",
        "src/observe/application/maintenance/storage.rs",
        "src/observe/application/maintenance/scan.rs",
        "src/observe/application/maintenance/status.rs",
        "src/observe/application/maintenance/inspection.rs",
        "src/observe/application/maintenance/catalog.rs",
        "src/observe/application/maintenance/mutations.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "observe maintenance split module should exist: {path}"
        );
    }
}

#[test]
fn workspace_compact_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let compact_mod = fs::read_to_string(root.join("src/workspace/compact/mod.rs")).unwrap();

    for needle in [
        "pub fn compact_project_dir(",
        "pub fn build_compact_handoff(",
        "pub fn save_compact_handoff(",
        "pub fn load_latest_compact_handoff(",
        "fn trim_history(",
        "mod tests {",
    ] {
        assert!(
            !compact_mod.contains(needle),
            "src/workspace/compact/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/workspace/compact/history.rs",
        "src/workspace/compact/paths.rs",
        "src/workspace/compact/storage.rs",
        "src/workspace/compact/tests.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "workspace compact split module should exist: {path}"
        );
    }
}

#[test]
fn workspace_compact_storage_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let storage_mod = fs::read_to_string(root.join("src/workspace/compact/storage.rs")).unwrap();

    for needle in [
        "fn trim_history(",
        "use std::result;",
        "use fs_err as fs;",
        "use tracing::warn;",
    ] {
        assert!(
            !storage_mod.contains(needle),
            "src/workspace/compact/storage.rs should stay focused on handoff persistence instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/workspace/compact/history.rs").exists(),
        "workspace compact history split module should exist"
    );
}

#[test]
fn infra_exec_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let exec_mod = fs::read_to_string(root.join("src/infra/exec/mod.rs")).unwrap();

    for needle in [
        "pub(crate) fn run_command(",
        "pub(crate) fn run_command_streaming(",
        "pub(crate) fn run_command_inherited(",
        "pub fn kubectl_rollout_restart(",
        "pub fn kumactl_run(",
        "mod tests {",
    ] {
        assert!(
            !exec_mod.contains(needle),
            "src/infra/exec/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/infra/exec/runner.rs",
        "src/infra/exec/docker/mod.rs",
        "src/infra/exec/docker/command.rs",
        "src/infra/exec/docker/compose.rs",
        "src/infra/exec/docker/container.rs",
        "src/infra/exec/docker/network.rs",
        "src/infra/exec/docker/token.rs",
        "src/infra/exec/tools.rs",
        "src/infra/exec/tests.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "infra exec split module should exist: {path}"
        );
    }
}

#[test]
fn infra_process_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let process = fs::read_to_string(root.join("src/infra/blocks/process.rs")).unwrap();

    for needle in [
        "fn std_process_executor_run_echo(",
        "fn fake_process_executor_panics_when_exhausted(",
        "mod tests {",
    ] {
        assert!(
            !process.contains(needle),
            "src/infra/blocks/process.rs should stay focused on production process execution instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/infra/blocks/process/tests.rs").exists(),
        "infra process split test module should exist"
    );
}

#[test]
fn observe_classifier_tests_stay_split_by_scenario() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let tests_mod = fs::read_to_string(root.join("src/observe/classifier/tests/mod.rs")).unwrap();

    for needle in [
        "fn detects_hook_denial(",
        "fn detects_harness_infrastructure_issue_phrase(",
        "fn resource_cleanup_tracks_apply_commands(",
        "fn truncated_verification_output_shape(",
    ] {
        assert!(
            !tests_mod.contains(needle),
            "src/observe/classifier/tests/mod.rs should stay a helper facade instead of owning `{needle}`"
        );
    }

    assert!(
        !root.join("src/observe/classifier/tests.rs").exists(),
        "src/observe/classifier/tests.rs should not return as a monolithic test file"
    );

    for path in [
        "src/observe/classifier/tests/mod.rs",
        "src/observe/classifier/tests/text_and_line.rs",
        "src/observe/classifier/tests/tool_use_patterns.rs",
        "src/observe/classifier/tests/assistant_diagnostics.rs",
        "src/observe/classifier/tests/tool_guard_patterns.rs",
        "src/observe/classifier/tests/workflow_rules.rs",
        "src/observe/classifier/tests/state_and_registry.rs",
        "src/observe/classifier/tests/query_tracking.rs",
        "src/observe/classifier/tests/resource_tracking.rs",
        "src/observe/classifier/tests/verification.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "observe classifier split test module should exist: {path}"
        );
    }
}

#[test]
fn observe_patterns_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let patterns = fs::read_to_string(root.join("src/observe/patterns.rs")).unwrap();

    for needle in [
        "fn ksa_codes_count(",
        "fn ksa_codes_sequential(",
        "mod tests {",
    ] {
        assert!(
            !patterns.contains(needle),
            "src/observe/patterns.rs should stay focused on production signal lists instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/observe/patterns/tests.rs").exists(),
        "observe patterns split test module should exist"
    );
}

#[test]
fn observe_classifier_text_checks_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let text_checks =
        fs::read_to_string(root.join("src/observe/classifier/text_checks.rs")).unwrap();

    for needle in [
        "fn check_ksa_codes(",
        "fn check_exit_code_issues(",
        "fn check_jq_errors(",
        "fn check_closeout_verdict_pending(",
        "fn check_runner_state_machine_stale(",
    ] {
        assert!(
            !text_checks.contains(needle),
            "src/observe/classifier/text_checks.rs should stay focused on non-Bash checks instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/observe/classifier/text_checks/bash.rs")
            .exists(),
        "observe classifier bash text checks split module should exist"
    );
}

#[test]
fn observe_classifier_rules_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let rules = fs::read_to_string(root.join("src/observe/classifier/rules.rs")).unwrap();

    for needle in [
        "pub(super) static TEXT_RULES:",
        "patterns::CLI_ERROR_PATTERNS",
        "patterns::CORPORATE_CLUSTER_SIGNALS",
    ] {
        assert!(
            !rules.contains(needle),
            "src/observe/classifier/rules.rs should stay focused on rule evaluation instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/observe/classifier/rules/data.rs").exists(),
        "observe classifier rules data split module should exist"
    );
}

#[test]
fn observe_dump_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let dump = fs::read_to_string(root.join("src/observe/dump.rs")).unwrap();

    for needle in [
        "pub(super) fn execute_dump(",
        "pub(super) fn format_dump_block(",
        "fn parse_dump_line(",
        "fn dump_message_content(",
        "fn dump_content_blocks(",
    ] {
        assert!(
            !dump.contains(needle),
            "src/observe/dump.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    assert_split_modules_exist(
        root,
        &["src/observe/dump/execute.rs", "src/observe/dump/format.rs"],
        "observe dump split module should exist",
    );
}

#[test]
fn observe_output_root_stays_focused_on_render_entrypoints() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let output = fs::read_to_string(root.join("src/observe/output.rs")).unwrap();

    for needle in [
        "struct RenderedIssue<'a>",
        "struct RenderedSummary",
        "struct RenderedTopCauses<'a>",
        "struct SarifProperties<'a>",
        "fn render_json_string<T>(",
        "fn render_property_bag<T>(",
    ] {
        assert!(
            !output.contains(needle),
            "src/observe/output.rs should stay focused on renderer entrypoints instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/observe/output/rendering.rs").exists(),
        "observe output rendering split module should exist"
    );
}
