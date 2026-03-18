mod build_info;
mod environment;
mod paths;
mod xdg;

pub use build_info::{BuildInfo, CommandResult, resolve_build_info};
pub use environment::host_platform;
pub(crate) use environment::merge_env;
pub use paths::{HARNESS_PREFIX, dirs_home, harness_data_root, shorten_path, utc_now};
pub use xdg::{
    current_run_context_path, data_root, project_context_dir, session_context_dir,
    session_scope_key, suite_root,
};

#[cfg(test)]
mod tests {
    #![allow(clippy::absolute_paths)]

    use crate::errors::{CliErrorKind, render_error};

    use super::*;

    #[test]
    fn cli_error_has_all_fields() {
        let err = CliErrorKind::command_failed("msg").with_details("more");
        assert_eq!(err.code(), "KSRCLI004");
        assert_eq!(err.message(), "command failed: msg");
        assert_eq!(err.exit_code(), 4);
        assert_eq!(err.details(), Some("more"));
    }

    #[test]
    fn render_error_includes_hint_and_details() {
        let err = CliErrorKind::MissingRunPointer.with_details("stack");
        let rendered = render_error(&err);
        assert!(
            rendered.contains("ERROR [KSRCLI005]"),
            "missing header: {rendered}"
        );
        assert!(
            rendered.contains("Hint: Run init first."),
            "missing hint: {rendered}"
        );
        assert!(rendered.contains("stack"), "missing details: {rendered}");
    }

    // All env-dependent tests are combined into one test to avoid races
    // from parallel test execution mutating the same env var.
    #[test]
    fn session_scope_and_context_path() {
        temp_env::with_vars([("CLAUDE_SESSION_ID", Some("combined-scope-test"))], || {
            // session_scope_key uses session prefix
            let key = session_scope_key().unwrap();
            assert!(
                key.starts_with("session-"),
                "expected session- prefix: {key}"
            );
            assert_eq!(
                key.len(),
                "session-".len() + 16,
                "digest should be 16 hex chars"
            );

            // deterministic: calling twice gives same result
            let key2 = session_scope_key().unwrap();
            assert_eq!(key, key2);

            // current_run_context_path is under session context dir
            let path = current_run_context_path().unwrap();
            assert!(
                path.ends_with("current-run.json"),
                "expected current-run.json suffix: {path:?}"
            );
            let parent_name = path
                .parent()
                .and_then(|p| p.file_name())
                .unwrap()
                .to_string_lossy();
            assert!(
                parent_name.starts_with("session-"),
                "expected session- prefix: {parent_name}"
            );
        });
    }

    #[test]
    fn session_scope_ignores_unset_sentinel() {
        temp_env::with_vars(
            [
                ("CLAUDE_SESSION_ID", Some("UNSET")),
                ("CLAUDE_PROJECT_DIR", None::<&str>),
            ],
            || {
                let key = session_scope_key().unwrap();
                assert!(
                    !key.starts_with("session-"),
                    "UNSET should not produce a session scope: {key}"
                );
            },
        );
    }
}
