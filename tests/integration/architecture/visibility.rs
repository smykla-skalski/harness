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
