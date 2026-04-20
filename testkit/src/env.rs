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

/// Initialize a git repository at `path` with a seed commit on the default
/// branch and one extra branch `branch_name` that carries one additional
/// commit.
///
/// The extra commit writes `branch.txt` so the branch diverges from the
/// default at a distinct SHA. Leaves HEAD on the default branch. Panics on
/// any git failure.
pub fn init_git_repo_with_branches(path: &Path, branch_name: &str) {
    init_git_repo_with_seed(path);
    // Capture the current (default) branch name so we can restore it after
    // creating the extra branch. HOME may point at a temp dir during tests, so
    // init.defaultBranch from the real global config is not available.
    let default_branch = {
        let out = Command::new("git")
            .current_dir(path)
            .args(["rev-parse", "--abbrev-ref", "HEAD"])
            .output()
            .expect("git rev-parse HEAD");
        String::from_utf8(out.stdout)
            .expect("utf8 branch name")
            .trim()
            .to_owned()
    };
    let checkout = Command::new("git")
        .current_dir(path)
        .args(["checkout", "-q", "-b", branch_name])
        .status()
        .expect("git checkout -b");
    assert!(checkout.success(), "git checkout -b failed");
    std::fs::write(path.join("branch.txt"), branch_name.as_bytes()).expect("write branch.txt");
    let add = Command::new("git")
        .current_dir(path)
        .args(["add", "branch.txt"])
        .status()
        .expect("git add branch.txt");
    assert!(add.success(), "git add branch.txt failed");
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
            branch_name,
        ])
        .status()
        .expect("git commit branch");
    assert!(commit.success(), "git commit branch failed");
    let back = Command::new("git")
        .current_dir(path)
        .args(["checkout", "-q", &default_branch])
        .status()
        .expect("git checkout default branch");
    assert!(back.success(), "git checkout default branch failed");
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
