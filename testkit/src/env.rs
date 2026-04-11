use std::path::Path;

/// Run a closure inside an isolated Harness filesystem scope.
///
/// Tests often set `XDG_DATA_HOME` to a temp dir but still accidentally see a
/// live Harness Monitor daemon because daemon discovery falls back to the real
/// account home for the app-group container path. This helper redirects both
/// Harness data and host-home discovery into the temp tree and clears daemon
/// root overrides so unit and integration tests cannot touch live app state.
pub fn with_isolated_harness_env<T>(base: &Path, action: impl FnOnce() -> T) -> T {
    let home = base.join("home");
    std::fs::create_dir_all(&home).expect("create isolated harness home");

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(base)),
            ("HOME", Some(home.as_path())),
            ("HARNESS_HOST_HOME", Some(home.as_path())),
            ("HARNESS_DAEMON_DATA_HOME", None::<&Path>),
            ("HARNESS_APP_GROUP_ID", None::<&Path>),
            ("HARNESS_SANDBOXED", None::<&Path>),
            ("CLAUDE_PROJECT_DIR", None::<&Path>),
            ("CLAUDE_SESSION_ID", None::<&Path>),
            ("CODEX_SESSION_ID", None::<&Path>),
            ("GEMINI_SESSION_ID", None::<&Path>),
            ("COPILOT_SESSION_ID", None::<&Path>),
            ("OPENCODE_SESSION_ID", None::<&Path>),
        ],
        action,
    )
}
