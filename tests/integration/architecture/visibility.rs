use std::fs;
use std::path::Path;

#[test]
fn application_submodules_are_not_public_library_surface() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, needle) in [
        ("src/run/mod.rs", "pub mod application;"),
        ("src/authoring/mod.rs", "pub mod application;"),
        ("src/hooks/mod.rs", "pub mod application;"),
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        assert!(
            !contents.contains(needle),
            "{path} should keep `application` crate-internal instead of exporting `{needle}`"
        );
        assert!(
            contents.contains("pub(crate) mod application;"),
            "{path} should expose `application` as crate-internal only"
        );
    }

    let hooks_root = fs::read_to_string(root.join("src/hooks/mod.rs")).unwrap();
    assert!(
        hooks_root.contains("pub use self::application::GuardContext;"),
        "src/hooks/mod.rs should re-export GuardContext as the stable public hook facade"
    );

    let testkit_builders = fs::read_to_string(root.join("testkit/src/builders.rs")).unwrap();
    assert!(
        !testkit_builders.contains("harness::hooks::application::GuardContext"),
        "testkit should not depend on the private hooks::application module"
    );
    assert!(
        testkit_builders.contains("harness::hooks::GuardContext"),
        "testkit should depend on the public hooks facade for GuardContext"
    );
}

#[test]
fn transport_command_modules_stay_internal_to_domains() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, needle) in [
        ("src/run/mod.rs", "pub mod commands;"),
        ("src/authoring/mod.rs", "pub mod commands;"),
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        assert!(
            !contents.contains(needle),
            "{path} should keep `commands` crate-internal instead of exporting `{needle}`"
        );
        assert!(
            contents.contains("pub(crate) mod commands;"),
            "{path} should expose `commands` as crate-internal only"
        );
    }

    for path in [
        "src/app/cli.rs",
        "tests/integration/helpers.rs",
        "tests/integration/cluster.rs",
        "tests/integration/commands/api.rs",
        "tests/integration/commands/init_run.rs",
        "tests/integration/commands/record.rs",
        "tests/integration/commands/report.rs",
        "tests/integration/commands/runner_state.rs",
        "tests/integration/commands/service.rs",
        "tests/integration/preflight.rs",
        "tests/integration/universal.rs",
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        assert!(
            !contents.contains("::commands::"),
            "{path} should depend on domain-root transport exports instead of `::commands::`"
        );
    }
}

#[test]
fn helper_modules_do_not_leak_publicly() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, public_needle, crate_needle) in [
        (
            "src/app/mod.rs",
            "pub mod command_context;",
            "pub(crate) mod command_context;",
        ),
        (
            "src/setup/mod.rs",
            "pub mod wrapper;",
            "pub(crate) mod wrapper;",
        ),
        (
            "src/observe/mod.rs",
            "pub mod classifier;",
            "pub(crate) mod classifier;",
        ),
        (
            "src/observe/mod.rs",
            "pub mod patterns;",
            "pub(crate) mod patterns;",
        ),
        (
            "src/observe/mod.rs",
            "pub mod session;",
            "pub(crate) mod session;",
        ),
        (
            "src/observe/mod.rs",
            "pub mod types;",
            "pub(crate) mod types;",
        ),
        (
            "src/hooks/mod.rs",
            "pub mod debug;",
            "pub(crate) mod debug;",
        ),
        (
            "src/hooks/mod.rs",
            "pub mod runner_policy;",
            "pub(crate) mod runner_policy;",
        ),
        (
            "src/hooks/mod.rs",
            "pub mod session;",
            "pub(crate) mod session;",
        ),
        (
            "src/hooks/mod.rs",
            "pub mod adapters;",
            "pub(crate) mod adapters;",
        ),
        (
            "src/hooks/mod.rs",
            "pub mod guards;",
            "pub(crate) mod guards;",
        ),
        (
            "src/hooks/mod.rs",
            "pub mod registry;",
            "pub(crate) mod registry;",
        ),
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        assert!(
            !contents.contains(public_needle),
            "{path} should not leak helper module `{public_needle}` publicly"
        );
        assert!(
            contents.contains(crate_needle),
            "{path} should keep helper module `{crate_needle}` crate-internal"
        );
    }

    let setup_session = fs::read_to_string(root.join("src/setup/session.rs")).unwrap();
    assert!(
        !setup_session.contains("crate::hooks::session::SessionStartHookOutput"),
        "src/setup/session.rs should not depend on the private hooks::session module"
    );
    assert!(
        setup_session.contains("crate::hooks::SessionStartHookOutput"),
        "src/setup/session.rs should use the public hooks facade for SessionStartHookOutput"
    );

    let hooks_root = fs::read_to_string(root.join("src/hooks/mod.rs")).unwrap();
    assert!(
        hooks_root.contains(
            "pub use self::session::{PreCompactHookInput, SessionStartHookInput, SessionStartHookOutput};"
        ),
        "src/hooks/mod.rs should re-export session hook payload types through the hooks facade"
    );
}

#[test]
fn errors_root_stays_a_transport_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let errors_mod = fs::read_to_string(root.join("src/errors/mod.rs")).unwrap();

    for needle in [
        "impl CliErrorKind {",
        "pub struct CliError {",
        "fn cli_err_basic_fields()",
        "mod tests {",
    ] {
        assert!(
            !errors_mod.contains(needle),
            "src/errors/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/errors/cli_kind.rs",
        "src/errors/cli_error.rs",
        "src/errors/tests.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "errors split module should exist: {path}"
        );
    }
}

#[test]
fn kernel_command_intent_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    assert!(
        !root.join("src/kernel/command_intent.rs").exists(),
        "legacy flat kernel command-intent module should not exist"
    );
    let command_intent_mod =
        fs::read_to_string(root.join("src/kernel/command_intent/mod.rs")).unwrap();

    for needle in [
        "pub struct ParsedCommand {",
        "pub struct ObservedCommand {",
        "pub struct HarnessCommandInvocationRef",
        "fn parse_harness_invocations(",
        "fn command_heads_basic()",
    ] {
        assert!(
            !command_intent_mod.contains(needle),
            "src/kernel/command_intent/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/kernel/command_intent/shell.rs",
        "src/kernel/command_intent/harness.rs",
        "src/kernel/command_intent/parsed.rs",
        "src/kernel/command_intent/observed.rs",
        "src/kernel/command_intent/fallback.rs",
        "src/kernel/command_intent/tests.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "kernel command_intent split module should exist: {path}"
        );
    }
}

#[test]
fn hooks_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hooks_mod = fs::read_to_string(root.join("src/hooks/mod.rs")).unwrap();

    for needle in [
        "pub enum HookType {",
        "pub enum HookCommand {",
        "pub struct HookArgs {",
        "define_legacy_hook!(",
        "pub fn run_hook_command(",
        "fn normalize_path(",
        "mod tests {",
    ] {
        assert!(
            !hooks_mod.contains(needle),
            "src/hooks/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/hooks/catalog.rs",
        "src/hooks/transport.rs",
        "src/hooks/runtime.rs",
        "src/hooks/write_surface.rs",
        "src/hooks/tests.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "hooks split module should exist: {path}"
        );
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
        "fn from_normalized_hydrates_missing_session_cwd(",
        "mod tests {",
    ] {
        assert!(
            !context.contains(needle),
            "src/hooks/application/context.rs should stay focused on production context hydration instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/hooks/application/context/tests.rs").exists(),
        "hooks application context split test module should exist"
    );
    assert!(
        root.join("src/hooks/application/context/hydration.rs")
            .exists(),
        "hooks application context hydration split module should exist"
    );
    assert!(
        root.join("src/hooks/application/context/interaction.rs")
            .exists(),
        "hooks application context interaction split module should exist"
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

#[test]
fn docker_block_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let docker_mod = fs::read_to_string(root.join("src/infra/blocks/docker/mod.rs")).unwrap();

    for needle in [
        "impl ContainerRuntime for DockerContainerRuntime",
        "struct FakeContainer {",
        "pub struct FakeContainerRuntime {",
        "mod tests {",
    ] {
        assert!(
            !docker_mod.contains(needle),
            "src/infra/blocks/docker/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/infra/blocks/docker/runtime.rs",
        "src/infra/blocks/docker/fake.rs",
        "src/infra/blocks/docker/tests.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "docker block split module should exist: {path}"
        );
    }
}

#[test]
fn compose_block_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let compose_mod = fs::read_to_string(root.join("src/infra/blocks/compose/mod.rs")).unwrap();

    for needle in [
        "pub struct DockerComposeOrchestrator",
        "pub struct FakeComposeOrchestrator",
        "mod tests {",
    ] {
        assert!(
            !compose_mod.contains(needle),
            "src/infra/blocks/compose/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/infra/blocks/compose/runtime.rs",
        "src/infra/blocks/compose/fake.rs",
        "src/infra/blocks/compose/tests.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "compose block split module should exist: {path}"
        );
    }
}

#[test]
fn helm_block_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let helm = fs::read_to_string(root.join("src/infra/blocks/helm.rs")).unwrap();

    for needle in [
        "fn helm_setting_parses_cli_arg(",
        "fn fake_package_deployer_tracks_release_state(",
        "mod tests {",
    ] {
        assert!(
            !helm.contains(needle),
            "src/infra/blocks/helm.rs should stay focused on production Helm deployment behavior instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/infra/blocks/helm/tests.rs").exists(),
        "helm block split test module should exist"
    );
}

#[test]
fn guard_bash_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let guard_bash_mod = fs::read_to_string(root.join("src/hooks/guard_bash/mod.rs")).unwrap();

    for needle in [
        "fn denies_direct_kubectl(",
        "fn allows_plain_echo(",
        "mod tests {",
    ] {
        assert!(
            !guard_bash_mod.contains(needle),
            "src/hooks/guard_bash/mod.rs should stay focused on production hook logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/hooks/guard_bash/tests.rs").exists(),
        "guard_bash split test module should exist"
    );
}

#[test]
fn verify_bash_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let verify_bash = fs::read_to_string(root.join("src/hooks/verify_bash.rs")).unwrap();

    for needle in [
        "fn subcommand_artifacts_apply(",
        "fn has_table_rows_with_enough_rows(",
        "mod tests {",
    ] {
        assert!(
            !verify_bash.contains(needle),
            "src/hooks/verify_bash.rs should stay focused on production hook logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/hooks/verify_bash/tests.rs").exists(),
        "verify_bash split test module should exist"
    );
}

#[test]
fn setup_capabilities_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let capabilities = fs::read_to_string(root.join("src/setup/capabilities.rs")).unwrap();

    for needle in [
        "fn capabilities_returns_zero(",
        "fn feature_count_is_current(",
        "mod tests {",
    ] {
        assert!(
            !capabilities.contains(needle),
            "src/setup/capabilities.rs should stay focused on production capability modeling instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/setup/capabilities/tests.rs").exists(),
        "setup capabilities split test module should exist"
    );
}

#[test]
fn setup_build_info_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let build_info = fs::read_to_string(root.join("src/setup/build_info.rs")).unwrap();

    for needle in ["fn build_info_env(", "mod tests {"] {
        assert!(
            !build_info.contains(needle),
            "src/setup/build_info.rs should stay focused on production build-info resolution instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/setup/build_info/tests.rs").exists(),
        "setup build_info split test module should exist"
    );
}

#[test]
fn setup_gateway_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let gateway = fs::read_to_string(root.join("src/setup/gateway.rs")).unwrap();

    for needle in [
        "fn detect_version_parses_standard_entry()",
        "fn install_url_embeds_arbitrary_version()",
        "mod tests {",
    ] {
        assert!(
            !gateway.contains(needle),
            "src/setup/gateway.rs should stay focused on production gateway setup instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/setup/gateway/tests.rs").exists(),
        "setup gateway split test module should exist"
    );
}

#[test]
fn authoring_workflow_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let workflow = fs::read_to_string(root.join("src/authoring/workflow.rs")).unwrap();

    for needle in [
        "fn author_phase_display(",
        "fn approval_mode_serialization(",
        "mod tests {",
    ] {
        assert!(
            !workflow.contains(needle),
            "src/authoring/workflow.rs should stay focused on production workflow logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/authoring/workflow/tests.rs").exists(),
        "authoring workflow split test module should exist"
    );
}

#[test]
fn kernel_topology_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let topology = fs::read_to_string(root.join("src/kernel/topology.rs")).unwrap();

    for needle in [
        "fn platform_display_roundtrip(",
        "fn current_deploy_round_trip(",
        "pub fn from_object(",
        "pub fn from_mode_with_platform(",
        "CurrentDeployPayload",
        "mod tests {",
    ] {
        assert!(
            !topology.contains(needle),
            "src/kernel/topology.rs should stay focused on production topology logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/kernel/topology/tests.rs").exists(),
        "kernel topology split test module should exist"
    );
    assert!(
        root.join("src/kernel/topology/parsing.rs").exists(),
        "kernel topology parsing split module should exist"
    );
    assert!(
        root.join("src/kernel/topology/current_deploy.rs").exists(),
        "kernel topology current_deploy split module should exist"
    );
}

#[test]
fn run_workflow_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let workflow = fs::read_to_string(root.join("src/run/workflow/mod.rs")).unwrap();

    for needle in [
        "fn runner_phase_display(",
        "fn apply_event_cluster_prepared_advances_to_preflight(",
        "mod tests {",
    ] {
        assert!(
            !workflow.contains(needle),
            "src/run/workflow/mod.rs should stay focused on production workflow logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/workflow/tests.rs").exists(),
        "run workflow split test module should exist"
    );
}

#[test]
fn run_task_output_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let task_output = fs::read_to_string(root.join("src/run/services/task_output.rs")).unwrap();

    for needle in [
        "fn extract_plain_text_line(",
        "fn extract_skips_user_messages(",
        "mod tests {",
    ] {
        assert!(
            !task_output.contains(needle),
            "src/run/services/task_output.rs should stay focused on production task-output parsing instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/services/task_output/tests.rs").exists(),
        "run task_output split test module should exist"
    );
}

#[test]
fn app_cli_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let cli = fs::read_to_string(root.join("src/app/cli.rs")).unwrap();

    for needle in [
        "fn all_expected_subcommands_registered(",
        "fn parse_init_command(",
        "mod tests {",
    ] {
        assert!(
            !cli.contains(needle),
            "src/app/cli.rs should stay focused on production CLI transport instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/app/cli/tests.rs").exists(),
        "app cli split test module should exist"
    );
}

#[test]
fn observe_output_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let output = fs::read_to_string(root.join("src/observe/output.rs")).unwrap();

    for needle in [
        "fn human_output_format(",
        "fn json_output_uses_nested_contract(",
        "mod tests {",
    ] {
        assert!(
            !output.contains(needle),
            "src/observe/output.rs should stay focused on production rendering logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/observe/output/tests.rs").exists(),
        "observe output split test module should exist"
    );
}

#[test]
fn observe_types_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let types_mod = fs::read_to_string(root.join("src/observe/types/mod.rs")).unwrap();

    for needle in [
        "fn render_format_displays_stable_names(",
        "fn focus_presets_static(",
        "mod tests {",
    ] {
        assert!(
            !types_mod.contains(needle),
            "src/observe/types/mod.rs should stay focused on production observe types instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/observe/types/tests.rs").exists(),
        "observe types split test module should exist"
    );
}

#[test]
fn observe_session_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let session = fs::read_to_string(root.join("src/observe/session.rs")).unwrap();

    for needle in [
        "fn find_session_in_temp_dir(",
        "fn find_session_ambiguous_without_hint(",
        "mod tests {",
    ] {
        assert!(
            !session.contains(needle),
            "src/observe/session.rs should stay focused on production session lookup instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/observe/session/tests.rs").exists(),
        "observe session split test module should exist"
    );
}

#[test]
fn run_prepared_suite_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let prepared_suite = fs::read_to_string(root.join("src/run/prepared_suite/mod.rs")).unwrap();

    for needle in [
        "fn prepared_suite_digests_tracking_defaults(",
        "fn to_json_includes_group_source_paths_and_manifest_metadata(",
        "mod tests {",
    ] {
        assert!(
            !prepared_suite.contains(needle),
            "src/run/prepared_suite/mod.rs should stay focused on production prepared-suite logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/prepared_suite/tests.rs").exists(),
        "run prepared_suite split test module should exist"
    );
}

#[test]
fn run_validated_layout_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let validated = fs::read_to_string(root.join("src/run/context/validated.rs")).unwrap();

    for needle in [
        "fn validated_layout_succeeds_for_existing_dir(",
        "fn validated_layout_into_inner_returns_original(",
        "mod tests {",
    ] {
        assert!(
            !validated.contains(needle),
            "src/run/context/validated.rs should stay focused on production validated-layout behavior instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/context/validated/tests.rs").exists(),
        "run validated-layout split test module should exist"
    );
}

#[test]
fn observe_registry_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let registry = fs::read_to_string(root.join("src/observe/classifier/registry.rs")).unwrap();

    for needle in [
        "static ISSUE_CODE_REGISTRY:",
        "fn registry_covers_all_codes(",
        "fn issue_owner_display(",
        "mod tests {",
    ] {
        assert!(
            !registry.contains(needle),
            "src/observe/classifier/registry.rs should stay focused on production registry data instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/observe/classifier/registry/tests.rs")
            .exists(),
        "observe classifier registry split test module should exist"
    );
    assert!(
        root.join("src/observe/classifier/registry/data.rs")
            .exists(),
        "observe classifier registry data module should exist"
    );
}

#[test]
fn runner_policy_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let runner_policy = fs::read_to_string(root.join("src/hooks/runner_policy.rs")).unwrap();

    for needle in [
        "pub enum LegacyScript {",
        "pub enum TaskOutputPattern {",
        "pub enum TrackedHarnessSubcommand {",
        "pub fn managed_cluster_binaries()",
        "pub fn is_manifest_fix_prompt(",
        "pub fn matches_manifest_fix_question(",
        "pub fn classify_canonical_gate(",
    ] {
        assert!(
            !runner_policy.contains(needle),
            "src/hooks/runner_policy.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/hooks/runner_policy/cluster.rs",
        "src/hooks/runner_policy/files.rs",
        "src/hooks/runner_policy/commands.rs",
        "src/hooks/runner_policy/questions.rs",
        "src/hooks/runner_policy/tests.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "runner_policy split module should exist: {path}"
        );
    }
}

#[test]
fn platform_runtime_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let runtime = fs::read_to_string(root.join("src/platform/runtime.rs")).unwrap();

    for needle in [
        "fn universal_runtime_exposes_control_plane_access(",
        "fn profile_platform_detects_universal_variants(",
        "mod tests {",
    ] {
        assert!(
            !runtime.contains(needle),
            "src/platform/runtime.rs should stay focused on production runtime access instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/platform/runtime/tests.rs").exists(),
        "platform runtime split test module should exist"
    );
}

#[test]
fn platform_ephemeral_metallb_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let metallb = fs::read_to_string(root.join("src/platform/ephemeral_metallb.rs")).unwrap();

    for needle in [
        "fn state_path_includes_state_dir(",
        "fn ensure_templates_fails_when_no_source(",
        "mod tests {",
    ] {
        assert!(
            !metallb.contains(needle),
            "src/platform/ephemeral_metallb.rs should stay focused on production template state handling instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/platform/ephemeral_metallb/tests.rs")
            .exists(),
        "platform ephemeral_metallb split test module should exist"
    );
}

#[test]
fn kubernetes_block_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let kubernetes_mod = fs::read_to_string(root.join("src/infra/blocks/kubernetes.rs")).unwrap();

    for needle in [
        "serde_json::from_str(&result.stdout)",
        "containerStatuses",
        "pub struct FakeKubernetesOperator {",
        "pub struct FakeLocalClusterManager {",
        "mod tests {",
    ] {
        assert!(
            !kubernetes_mod.contains(needle),
            "src/infra/blocks/kubernetes.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/infra/blocks/kubernetes/fake.rs",
        "src/infra/blocks/kubernetes/pods.rs",
        "src/infra/blocks/kubernetes/tests.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "kubernetes block split module should exist: {path}"
        );
    }
}

#[test]
fn setup_universal_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let universal_mod = fs::read_to_string(root.join("src/setup/cluster/universal.rs")).unwrap();

    for needle in [
        "fn universal_single_up(",
        "fn universal_global_zone_up(",
        "fn universal_global_two_zones_up(",
    ] {
        assert!(
            !universal_mod.contains(needle),
            "src/setup/cluster/universal.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/setup/cluster/universal/config.rs",
        "src/setup/cluster/universal/runtime.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "setup universal split module should exist: {path}"
        );
    }
}

#[test]
fn setup_universal_runtime_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let runtime = fs::read_to_string(root.join("src/setup/cluster/universal/runtime.rs")).unwrap();

    for needle in [
        "fn universal_single_up_compose(",
        "fn universal_global_zone_up(",
        "fn universal_global_two_zones_up(",
        "mod tests {",
    ] {
        assert!(
            !runtime.contains(needle),
            "src/setup/cluster/universal/runtime.rs should stay focused on runtime dispatch instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/setup/cluster/universal/runtime/compose.rs")
            .exists(),
        "setup universal runtime compose split module should exist"
    );
}

#[test]
fn run_services_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let run_services = fs::read_to_string(root.join("src/run/services/mod.rs")).unwrap();

    for needle in [
        "fn write_suite(",
        "fn prepare_preflight_run(",
        "mod tests {",
    ] {
        assert!(
            !run_services.contains(needle),
            "src/run/services/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/services/tests.rs").exists(),
        "run services split test module should exist"
    );
}

#[test]
fn run_audit_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let run_audit = fs::read_to_string(root.join("src/run/audit/mod.rs")).unwrap();

    for needle in [
        "fn sample_status(",
        "fn assert_audit_entry_fields(",
        "mod tests {",
    ] {
        assert!(
            !run_audit.contains(needle),
            "src/run/audit/mod.rs should stay focused on production audit logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/audit/tests.rs").exists(),
        "run audit split test module should exist"
    );
}

#[test]
fn versioned_json_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let versioned_json =
        fs::read_to_string(root.join("src/infra/persistence/versioned_json.rs")).unwrap();

    for needle in [
        "fn load_returns_none_when_file_missing(",
        "fn update_serializes_concurrent_writers(",
        "mod tests {",
    ] {
        assert!(
            !versioned_json.contains(needle),
            "src/infra/persistence/versioned_json.rs should stay focused on production persistence logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/infra/persistence/versioned_json/tests.rs")
            .exists(),
        "versioned json split test module should exist"
    );
}

#[test]
fn run_resolve_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let resolve_mod = fs::read_to_string(root.join("src/run/resolve.rs")).unwrap();

    for needle in [
        "fn resolve_run_directory_with_existing_dir()",
        "fn resolve_manifest_path_leading_slash_treated_as_relative()",
        "mod tests {",
    ] {
        assert!(
            !resolve_mod.contains(needle),
            "src/run/resolve.rs should stay focused on production resolution logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/resolve/tests.rs").exists(),
        "run resolve split test module should exist"
    );
}

#[test]
fn run_state_capture_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let state_capture = fs::read_to_string(root.join("src/run/state_capture.rs")).unwrap();

    for needle in [
        "fn dataplane_collection_extracts_known_fields()",
        "fn dataplane_snapshot_reads_nested_meta_fields()",
        "mod tests {",
    ] {
        assert!(
            !state_capture.contains(needle),
            "src/run/state_capture.rs should stay focused on production capture types instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/state_capture/tests.rs").exists(),
        "run state_capture split test module should exist"
    );
}

#[test]
fn infra_io_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let infra_io = fs::read_to_string(root.join("src/infra/io/mod.rs")).unwrap();

    for needle in [
        "fn write_and_read_json(",
        "fn append_markdown_row_appends_to_existing(",
        "mod tests {",
    ] {
        assert!(
            !infra_io.contains(needle),
            "src/infra/io/mod.rs should stay focused on production io helpers instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/infra/io/tests.rs").exists(),
        "infra io split test module should exist"
    );
}
