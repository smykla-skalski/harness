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
    let context = fs::read_to_string(root.join("crates/harness-hooks/src/application/context.rs")).unwrap();

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
            "crates/harness-hooks/src/application/context.rs should stay focused on production context hydration instead of owning `{needle}`"
        );
    }

    assert_split_modules_exist(
        root,
        &[
            "crates/harness-hooks/src/application/context/tests.rs",
            "crates/harness-hooks/src/application/context/hydration.rs",
            "crates/harness-hooks/src/application/context/interaction.rs",
        ],
        "hooks application context split module should exist",
    );
    assert_split_modules_exist(
        root,
        &["crates/harness-hooks/src/application/context/command.rs"],
        "hooks application context split module should exist",
    );
}

#[test]
fn hook_protocol_roots_stay_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, needles, split_path) in [
        (
            "crates/harness-hooks/src/protocol/output.rs",
            &[
                "fn render_hook_message_deny()",
                "fn hook_output_allow_is_always_empty()",
                "mod tests {",
            ][..],
            "crates/harness-hooks/src/protocol/output/tests.rs",
        ),
        (
            "crates/harness-hooks/src/protocol/payloads.rs",
            &[
                "fn envelope_from_str_parses()",
                "fn response_text_renders_bash_output()",
                "mod tests {",
            ][..],
            "crates/harness-hooks/src/protocol/payloads/tests.rs",
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
            "crates/harness-hooks/src/session.rs",
            &[
                "fn session_start_output_from_additional_context()",
                "fn resolve_cwd_falls_back_to_project_dir()",
                "mod tests {",
            ][..],
            "crates/harness-hooks/src/session/tests.rs",
        ),
        (
            "crates/harness-kernel/src/redact.rs",
            &[
                "fn scrubs_pem_certificate()",
                "fn scrubs_multiple_patterns_in_one_pass()",
                "mod tests {",
            ][..],
            "crates/harness-kernel/src/redact/tests.rs",
        ),
        (
            "crates/harness-kernel/src/errors/hook_result.rs",
            &[
                "fn allow_has_empty_code_and_message()",
                "fn clone_is_equal()",
                "mod tests {",
            ][..],
            "crates/harness-kernel/src/errors/hook_result/tests.rs",
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
