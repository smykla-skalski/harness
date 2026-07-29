use std::path::Path;

use super::helpers::{read_repo_file, repo_path_exists};

#[test]
fn transport_command_modules_stay_internal_to_domains() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for path in [
        "src/app/cli.rs",
        "tests/integration/helpers.rs",
        "tests/integration/cluster/mod.rs",
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
            "pub use harness_workspace::command_context;",
            "pub(crate) use harness_workspace::command_context;",
        ),
        (
            "src/setup/mod.rs",
            "pub use harness_hooks::wrapper;",
            "pub(crate) use harness_hooks::wrapper;",
        ),
        (
            "src/observe/mod.rs",
            "pub mod types;",
            "pub(crate) mod types {",
        ),
        // `harness_hooks`'s root re-exports everything through root's
        // `pub use harness_hooks::*;` glob facade, so a module that flips
        // from `pub(crate)` to `pub` here leaks through that facade the
        // same way it would have leaked through `src/hooks/mod.rs` before
        // the extraction.
        (
            "crates/harness-hooks/src/lib.rs",
            "pub mod application;",
            "pub(crate) mod application;",
        ),
        (
            "crates/harness-hooks/src/lib.rs",
            "pub mod registry;",
            "pub(crate) mod registry;",
        ),
        (
            "crates/harness-hooks/src/lib.rs",
            "pub mod session;",
            "pub(crate) mod session;",
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
}

#[test]
fn errors_root_stays_a_transport_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let errors_mod = read_repo_file(root, "crates/harness-kernel/src/errors/mod.rs");

    for needle in [
        "impl CliErrorKind {",
        "pub struct CliError {",
        "fn cli_err_basic_fields()",
        "mod tests {",
    ] {
        assert!(
            !errors_mod.contains(needle),
            "crates/harness-kernel/src/errors/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "crates/harness-kernel/src/errors/cli_kind/mod.rs",
        "crates/harness-kernel/src/errors/cli_kind/common.rs",
        "crates/harness-kernel/src/errors/cli_kind/run_setup.rs",
        "crates/harness-kernel/src/errors/cli_kind/create_observe.rs",
        "crates/harness-kernel/src/errors/cli_kind/workflow.rs",
        "crates/harness-kernel/src/errors/hook_message/mod.rs",
        "crates/harness-kernel/src/errors/hook_message/constructors.rs",
        "crates/harness-kernel/src/errors/hook_message/mapping.rs",
        "crates/harness-kernel/src/errors/run_setup/mod.rs",
        "crates/harness-kernel/src/errors/run_setup/constructors.rs",
        "crates/harness-kernel/src/errors/run_setup/hints.rs",
        "crates/harness-kernel/src/errors/cli_error.rs",
        "crates/harness-kernel/src/errors/tests.rs",
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
    let cli_kind = read_repo_file(root, "crates/harness-kernel/src/errors/cli_kind/mod.rs");

    for needle in [
        "pub fn missing_tools(",
        "pub fn report_line_limit(",
        "pub fn session_parse_error(",
        "pub fn workflow_io(",
    ] {
        assert!(
            !cli_kind.contains(needle),
            "crates/harness-kernel/src/errors/cli_kind/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }
}

#[test]
fn errors_run_setup_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let run_setup = read_repo_file(root, "crates/harness-kernel/src/errors/run_setup/mod.rs");

    for needle in [
        "pub fn missing_closeout_artifact(",
        "pub fn report_line_limit(",
        "pub fn hint(&self)",
    ] {
        assert!(
            !run_setup.contains(needle),
            "crates/harness-kernel/src/errors/run_setup/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }
}

#[test]
fn errors_hook_message_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hook_message = read_repo_file(root, "crates/harness-kernel/src/errors/hook_message/mod.rs");

    for needle in [
        "pub fn write_outside_run(",
        "pub fn code(&self)",
        "pub fn decision(&self)",
    ] {
        assert!(
            !hook_message.contains(needle),
            "crates/harness-kernel/src/errors/hook_message/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }
}

#[test]
fn kernel_command_intent_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    assert!(
        !root
            .join("crates/harness-kernel/src/kernel/command_intent.rs")
            .exists(),
        "legacy flat kernel command-intent module should not exist"
    );
    let command_intent_mod = read_repo_file(
        root,
        "crates/harness-kernel/src/kernel/command_intent/mod.rs",
    );

    for needle in [
        "pub struct ParsedCommand {",
        "pub struct ObservedCommand {",
        "pub struct HarnessCommandInvocationRef",
        "fn parse_harness_invocations(",
        "fn command_heads_basic()",
    ] {
        assert!(
            !command_intent_mod.contains(needle),
            "crates/harness-kernel/src/kernel/command_intent/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "crates/harness-kernel/src/kernel/command_intent/shell.rs",
        "crates/harness-kernel/src/kernel/command_intent/harness.rs",
        "crates/harness-kernel/src/kernel/command_intent/parsed.rs",
        "crates/harness-kernel/src/kernel/command_intent/observed.rs",
        "crates/harness-kernel/src/kernel/command_intent/fallback.rs",
        "crates/harness-kernel/src/kernel/command_intent/tests.rs",
    ] {
        assert!(
            repo_path_exists(root, path),
            "kernel command_intent split module should exist: {path}"
        );
    }
}
