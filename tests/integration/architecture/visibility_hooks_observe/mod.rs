use std::fs;
use std::path::Path;

mod observe_workspace;

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
fn create_workflow_root_stays_focused_on_runtime_state() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let workflow = fs::read_to_string(root.join("src/create/workflow.rs")).unwrap();

    for needle in [
        "struct StoredCreateWorkflowData",
        "struct StoredCreateWorkflowState",
        "fn to_stored(&self)",
        "fn from_stored(",
        "fn serialize<S>(",
        "fn deserialize<D>(",
        "pub fn create_state_path()",
        "pub fn read_create_state()",
        "pub fn write_create_state(",
        "pub fn can_write(",
        "pub fn can_request_gate(",
        "pub enum CreateNextAction",
        "pub fn next_action(",
    ] {
        assert!(
            !workflow.contains(needle),
            "src/create/workflow.rs should stay focused on runtime state and gating instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/create/workflow/storage.rs").exists(),
        "create workflow storage split module should exist"
    );
    assert!(
        root.join("src/create/workflow/policy.rs").exists(),
        "create workflow policy split module should exist"
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
fn hook_misc_roots_stay_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, needles, split_path) in [
        (
            "src/hooks/session.rs",
            &[
                "fn session_start_output_from_additional_context()",
                "fn resolve_cwd_falls_back_to_project_dir()",
                "mod tests {",
            ][..],
            "src/hooks/session/tests.rs",
        ),
        (
            "src/hooks/audit.rs",
            &[
                "fn is_silent_suite_runner()",
                "fn writes_audit_entry_for_suite_run_hook()",
                "mod tests {",
            ][..],
            "src/hooks/audit/tests.rs",
        ),
        (
            "src/hooks/enrich_failure.rs",
            &[
                "fn request_failure_triage_sets_phase_and_failure()",
                "fn request_preflight_failed_resets_status()",
                "mod tests {",
            ][..],
            "src/hooks/enrich_failure/tests.rs",
        ),
        (
            "src/hooks/verify_write.rs",
            &[
                "fn verify_suite_create_empty_amendments_denies()",
                "fn verify_suite_runner_accumulates_suite_and_amendments_writes()",
                "mod tests {",
            ][..],
            "src/hooks/verify_write/tests.rs",
        ),
        (
            "src/hooks/protocol/hook_result.rs",
            &[
                "fn allow_has_empty_code_and_message()",
                "fn clone_is_equal()",
                "mod tests {",
            ][..],
            "src/hooks/protocol/hook_result/tests.rs",
        ),
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        for needle in needles {
            assert!(
                !contents.contains(needle),
                "{path} should stay focused on production hook runtime logic instead of owning `{needle}`"
            );
        }
        assert!(
            root.join(split_path).exists(),
            "hook misc split test module should exist: {split_path}"
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
                "fn create_denies_rm_rf_suite_dir()",
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
