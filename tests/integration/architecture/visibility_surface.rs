use std::path::Path;

use super::helpers::{collect_hits_in_tree, read_repo_file, repo_path_exists};

#[test]
fn application_submodules_are_not_public_library_surface() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, needle) in [
        ("src/run/mod.rs", "pub mod application;"),
        ("src/create/mod.rs", "pub mod application;"),
        ("src/hooks/mod.rs", "pub mod application;"),
    ] {
        let contents = read_repo_file(root, path);
        assert!(
            !contents.contains(needle),
            "{path} should keep `application` crate-internal instead of exporting `{needle}`"
        );
        assert!(
            contents.contains("pub(crate) mod application;"),
            "{path} should expose `application` as crate-internal only"
        );
    }

    let hooks_root = read_repo_file(root, "src/hooks/mod.rs");
    assert!(
        hooks_root.contains("pub use self::application::GuardContext;"),
        "src/hooks/mod.rs should re-export GuardContext as the stable public hook facade"
    );

    let private_guard_context_hits = collect_hits_in_tree(
        &root.join("testkit/src/builders"),
        root,
        None,
        &["harness::hooks::application::GuardContext"],
        |path, needle| format!("{path} still depends on private hook application via `{needle}`"),
    );
    assert!(
        private_guard_context_hits.is_empty(),
        "testkit should not depend on the private hooks::application module"
    );
    let public_guard_context_hits = collect_hits_in_tree(
        &root.join("testkit/src/builders"),
        root,
        None,
        &["harness::hooks::GuardContext"],
        |path, needle| format!("{path} depends on `{needle}`"),
    );
    assert!(
        !public_guard_context_hits.is_empty(),
        "testkit should depend on the public hooks facade for GuardContext"
    );
}

#[test]
fn transport_command_modules_stay_internal_to_domains() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, needle) in [
        ("src/run/mod.rs", "pub mod commands;"),
        ("src/create/mod.rs", "pub mod commands;"),
    ] {
        let contents = read_repo_file(root, path);
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
        "tests/integration/cluster/mod.rs",
        "tests/integration/cluster/orchestration.rs",
        "tests/integration/commands/api.rs",
        "tests/integration/commands/init_run.rs",
        "tests/integration/commands/record.rs",
        "tests/integration/commands/report.rs",
        "tests/integration/commands/runner_state.rs",
        "tests/integration/commands/service.rs",
        "tests/integration/preflight.rs",
        "tests/integration/universal.rs",
    ] {
        let contents = read_repo_file(root, path);
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
        let contents = read_repo_file(root, path);
        assert!(
            !contents.contains(public_needle),
            "{path} should not leak helper module `{public_needle}` publicly"
        );
        assert!(
            contents.contains(crate_needle),
            "{path} should keep helper module `{crate_needle}` crate-internal"
        );
    }

    let setup_session = read_repo_file(root, "src/setup/session.rs");
    assert!(
        !setup_session.contains("crate::hooks::session::SessionStartHookOutput"),
        "src/setup/session.rs should not depend on the private hooks::session module"
    );
    assert!(
        setup_session.contains("crate::hooks::SessionStartHookOutput"),
        "src/setup/session.rs should use the public hooks facade for SessionStartHookOutput"
    );

    let hooks_root = read_repo_file(root, "src/hooks/mod.rs");
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
    let errors_mod = read_repo_file(root, "src/errors/mod.rs");

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
        "src/errors/cli_kind/mod.rs",
        "src/errors/cli_kind/common.rs",
        "src/errors/cli_kind/run_setup.rs",
        "src/errors/cli_kind/create_observe.rs",
        "src/errors/cli_kind/workflow.rs",
        "src/errors/hook_message/mod.rs",
        "src/errors/hook_message/constructors.rs",
        "src/errors/hook_message/mapping.rs",
        "src/errors/run_setup/mod.rs",
        "src/errors/run_setup/constructors.rs",
        "src/errors/run_setup/hints.rs",
        "src/errors/cli_error.rs",
        "src/errors/tests.rs",
    ] {
        assert!(
            repo_path_exists(root, path),
            "errors split module should exist: {path}"
        );
    }
}

#[test]
fn errors_cli_kind_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let cli_kind = read_repo_file(root, "src/errors/cli_kind/mod.rs");

    for needle in [
        "pub fn missing_tools(",
        "pub fn report_line_limit(",
        "pub fn session_parse_error(",
        "pub fn workflow_io(",
    ] {
        assert!(
            !cli_kind.contains(needle),
            "src/errors/cli_kind/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }
}

#[test]
fn errors_run_setup_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let run_setup = read_repo_file(root, "src/errors/run_setup/mod.rs");

    for needle in [
        "pub fn missing_closeout_artifact(",
        "pub fn report_line_limit(",
        "pub fn hint(&self)",
    ] {
        assert!(
            !run_setup.contains(needle),
            "src/errors/run_setup/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }
}

#[test]
fn errors_hook_message_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hook_message = read_repo_file(root, "src/errors/hook_message/mod.rs");

    for needle in [
        "pub fn write_outside_run(",
        "pub fn code(&self)",
        "pub fn decision(&self)",
    ] {
        assert!(
            !hook_message.contains(needle),
            "src/errors/hook_message/mod.rs should stay a thin facade instead of owning `{needle}`"
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
    let command_intent_mod = read_repo_file(root, "src/kernel/command_intent/mod.rs");

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
            repo_path_exists(root, path),
            "kernel command_intent split module should exist: {path}"
        );
    }
}

#[test]
fn hooks_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hooks_mod = read_repo_file(root, "src/hooks/mod.rs");

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
            repo_path_exists(root, path),
            "hooks split module should exist: {path}"
        );
    }
}
