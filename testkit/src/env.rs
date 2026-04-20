use std::path::Path;
use std::process::Command;

/// Initialize an empty git repository at `path` with a single seed commit so
/// downstream callers (notably the daemon's `WorktreeController`) have a
/// resolvable HEAD to branch from.
///
/// Creates the directory if it does not exist; panics on any git failure
/// because tests rely on a deterministic repo state.
pub fn init_git_repo_with_seed(path: &Path) {
    std::fs::create_dir_all(path).expect("create git repo dir");
    let init = Command::new("git")
        .arg("init")
        .arg("-q")
        .arg(path)
        .status()
        .expect("git init");
    assert!(init.success(), "git init failed at {}", path.display());
    std::fs::write(path.join("README.md"), b"seed\n").expect("seed README");
    let add = Command::new("git")
        .current_dir(path)
        .args(["add", "README.md"])
        .status()
        .expect("git add");
    assert!(add.success(), "git add failed at {}", path.display());
    let commit = Command::new("git")
        .current_dir(path)
        .args([
            "-c",
            "user.email=test@example.com",
            "-c",
            "user.name=test",
            "commit",
            "-q",
            "-m",
            "seed",
        ])
        .status()
        .expect("git commit");
    assert!(commit.success(), "git commit failed at {}", path.display());
}

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
