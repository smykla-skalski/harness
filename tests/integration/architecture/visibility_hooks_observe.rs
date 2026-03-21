use std::fs;
use std::path::Path;

fn assert_split_modules_exist(root: &Path, paths: &[&str], message: &str) {
    for path in paths {
        assert!(root.join(path).exists(), "{message}: {path}");
    }
}

#[test]
fn hooks_application_context_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let context = fs::read_to_string(root.join("src/hooks/application/context.rs")).unwrap();

    for needle in [
        "struct HookInteraction {",
        "struct HydratedHookState {",
        "fn normalized_from_envelope(",
        "fn hydrate_normalized_context(",
        "pub fn effective_run_dir(&self)",
        "pub fn command_text(&self)",
        "pub fn parsed_command(&self)",
        "fn from_normalized_hydrates_missing_session_cwd(",
        "mod tests {",
    ] {
        assert!(
            !context.contains(needle),
            "src/hooks/application/context.rs should stay focused on production context hydration instead of owning `{needle}`"
        );
    }

    assert_split_modules_exist(
        root,
        &[
            "src/hooks/application/context/tests.rs",
            "src/hooks/application/context/hydration.rs",
            "src/hooks/application/context/interaction.rs",
        ],
        "hooks application context split module should exist",
    );
    assert_split_modules_exist(
        root,
        &[
            "src/hooks/application/context/command.rs",
            "src/hooks/application/context/view.rs",
        ],
        "hooks application context split module should exist",
    );
}

#[test]
fn context_agent_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let context_agent = fs::read_to_string(root.join("src/hooks/context_agent.rs")).unwrap();

    for needle in [
        "use crate::errors::{CliError, HookMessage};",
        "use crate::hooks::application::GuardContext as HookContext;",
        "use crate::run::workflow::{PreflightStatus, RunnerPhase, RunnerWorkflowState};",
        "use super::effects::{HookEffect, HookOutcome};",
        "fn can_start_preflight_worker(",
        "mod tests {",
    ] {
        assert!(
            !context_agent.contains(needle),
            "src/hooks/context_agent.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    assert_split_modules_exist(
        root,
        &[
            "src/hooks/context_agent/runtime.rs",
            "src/hooks/context_agent/tests.rs",
        ],
        "context-agent split module should exist",
    );
}

#[test]
fn authoring_workflow_root_stays_focused_on_runtime_state() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let workflow = fs::read_to_string(root.join("src/authoring/workflow.rs")).unwrap();

    for needle in [
        "struct StoredAuthorWorkflowData",
        "struct StoredAuthorWorkflowState",
        "fn to_stored(&self)",
        "fn from_stored(",
        "fn serialize<S>(",
        "fn deserialize<D>(",
        "pub fn author_state_path()",
        "pub fn read_author_state()",
        "pub fn write_author_state(",
        "pub fn can_write(",
        "pub fn can_request_gate(",
        "pub enum AuthorNextAction",
        "pub fn next_action(",
    ] {
        assert!(
            !workflow.contains(needle),
            "src/authoring/workflow.rs should stay focused on runtime state and gating instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/authoring/workflow/storage.rs").exists(),
        "authoring workflow storage split module should exist"
    );
    assert!(
        root.join("src/authoring/workflow/policy.rs").exists(),
        "authoring workflow policy split module should exist"
    );
}

#[test]
fn question_and_stop_hooks_root_stay_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, needles) in [
        (
            "src/hooks/guard_question.rs",
            &[
                "fn triage_with_failure_allows_manifest_fix()",
                "fn execution_phase_denies_manifest_fix()",
                "mod tests {",
            ][..],
        ),
        (
            "src/hooks/guard_stop.rs",
            &["fn inactive_skill_allows()", "mod tests {"][..],
        ),
        (
            "src/hooks/verify_question.rs",
            &["fn inactive_skill_allows()", "mod tests {"][..],
        ),
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        for needle in needles {
            assert!(
                !contents.contains(needle),
                "{path} should stay focused on production hook logic instead of owning `{needle}`"
            );
        }
    }

    for path in [
        "src/hooks/guard_question/tests.rs",
        "src/hooks/guard_stop/tests.rs",
        "src/hooks/verify_question/tests.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "question/stop hook split test module should exist: {path}"
        );
    }
}

#[test]
fn validate_agent_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let validate_agent = fs::read_to_string(root.join("src/hooks/validate_agent.rs")).unwrap();

    assert!(
        !validate_agent.contains("mod tests {"),
        "src/hooks/validate_agent.rs should stay focused on production hook logic instead of owning embedded tests"
    );
    assert!(
        root.join("src/hooks/validate_agent/tests.rs").exists(),
        "validate_agent split test module should exist"
    );
}

#[test]
fn hooks_debug_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let debug = fs::read_to_string(root.join("src/hooks/debug.rs")).unwrap();

    for needle in [
        "fn allow_returns_zero_exit_code()",
        "fn log_and_exit_writes_jsonl_debug_file()",
        "mod tests {",
    ] {
        assert!(
            !debug.contains(needle),
            "src/hooks/debug.rs should stay focused on production debug logging instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/hooks/debug/tests.rs").exists(),
        "hooks debug split test module should exist"
    );
}

#[test]
fn hook_protocol_roots_stay_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, needles, split_path) in [
        (
            "src/hooks/protocol/output.rs",
            &[
                "fn render_hook_message_deny()",
                "fn hook_output_allow_is_always_empty()",
                "mod tests {",
            ][..],
            "src/hooks/protocol/output/tests.rs",
        ),
        (
            "src/hooks/protocol/payloads.rs",
            &[
                "fn envelope_from_str_parses()",
                "fn response_text_renders_bash_output()",
                "mod tests {",
            ][..],
            "src/hooks/protocol/payloads/tests.rs",
        ),
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        for needle in needles {
            assert!(
                !contents.contains(needle),
                "{path} should stay focused on production hook protocol logic instead of owning `{needle}`"
            );
        }
        assert!(
            root.join(split_path).exists(),
            "hook protocol split test module should exist: {split_path}"
        );
    }
}

#[test]
fn guard_write_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let guard_write = fs::read_to_string(root.join("src/hooks/guard_write.rs")).unwrap();

    for needle in [
        "fn allowed_path_for_run_metadata(",
        "fn file_label_with_filename(",
        "mod tests {",
    ] {
        assert!(
            !guard_write.contains(needle),
            "src/hooks/guard_write.rs should stay focused on production write-guard logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/hooks/guard_write/tests.rs").exists(),
        "guard-write split test module should exist"
    );
}

#[test]
fn runner_guards_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let runner_guards =
        fs::read_to_string(root.join("src/hooks/guard_bash/runner_guards.rs")).unwrap();

    for needle in [
        "fn completed_run_reuse_reason(",
        "fn allowed_command(",
        "fn tracked_harness_subcommands(",
        "fn run_control_files_mentioned(",
        "fn tracked_kubectl_delete_words(",
    ] {
        assert!(
            !runner_guards.contains(needle),
            "src/hooks/guard_bash/runner_guards.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/hooks/guard_bash/runner_guards/phase.rs",
        "src/hooks/guard_bash/runner_guards/structural.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "runner guards split module should exist: {path}"
        );
    }
}

#[test]
fn hook_guards_roots_stay_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, needles, split_path) in [
        (
            "src/hooks/guards/admin_endpoint.rs",
            &[
                "fn denies_direct_admin_endpoint()",
                "fn allows_harness_envoy_capture()",
                "mod tests {",
            ][..],
            "src/hooks/guards/admin_endpoint/tests.rs",
        ),
        (
            "src/hooks/guards/denied_binary.rs",
            &[
                "fn runner_denies_kubectl()",
                "fn author_denies_rm_rf_suite_dir()",
                "mod tests {",
            ][..],
            "src/hooks/guards/denied_binary/tests.rs",
        ),
        (
            "src/hooks/guards/make_target.rs",
            &[
                "fn denies_k3d_make_target()",
                "fn allows_safe_make_target()",
                "mod tests {",
            ][..],
            "src/hooks/guards/make_target/tests.rs",
        ),
        (
            "src/hooks/guards/run_phase.rs",
            &[
                "fn allows_when_no_runner_state()",
                "fn allows_plain_command()",
                "mod tests {",
            ][..],
            "src/hooks/guards/run_phase/tests.rs",
        ),
        (
            "src/hooks/guards/structural.rs",
            &[
                "fn denies_batched_tracked_harness_in_loop()",
                "fn allows_single_kuma_delete()",
                "mod tests {",
            ][..],
            "src/hooks/guards/structural/tests.rs",
        ),
        (
            "src/hooks/guards/subshell.rs",
            &[
                "fn denies_kubectl_in_subshell()",
                "fn allows_safe_subshell()",
                "mod tests {",
            ][..],
            "src/hooks/guards/subshell/tests.rs",
        ),
        (
            "src/hooks/guards/mod.rs",
            &[
                "fn empty_chain_allows()",
                "fn subshell_smuggling_caught_before_binary_check()",
                "mod tests {",
            ][..],
            "src/hooks/guards/tests.rs",
        ),
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        for needle in needles {
            assert!(
                !contents.contains(needle),
                "{path} should stay focused on production hook guard logic instead of owning `{needle}`"
            );
        }
        assert!(
            root.join(split_path).exists(),
            "hook guard split test module should exist: {split_path}"
        );
    }
}

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
