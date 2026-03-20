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
fn observe_registry_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let registry = fs::read_to_string(root.join("src/observe/classifier/registry.rs")).unwrap();

    for needle in [
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
    ] {
        assert!(
            root.join(path).exists(),
            "runner_policy split module should exist: {path}"
        );
    }
}
