use std::path::Path;
use std::process::Command;

/// Initialize an empty git repository at `path` with a single seed commit so
/// downstream callers (notably the daemon's `WorktreeController`) have a
/// resolvable HEAD to branch from.
///
/// Creates the directory if it does not exist.
///
/// # Panics
///
/// Panics on any git failure because tests rely on a deterministic repo state.
pub fn init_git_repo_with_seed(path: &Path) {
    std::fs::create_dir_all(path).expect("create git repo dir");

    run_git(path, &["init"]);
    run_git(path, &["config", "user.email", "test@example.com"]);
    run_git(path, &["config", "user.name", "test"]);

    std::fs::write(path.join("README.md"), b"seed\n").expect("seed README");

    run_git(path, &["add", "README.md"]);
    run_git(path, &["-c", "commit.gpgsign=false", "commit", "-m", "seed"]);
}

/// Initialize a git repository at `path` with a seed commit on the default
/// branch and one extra branch `branch_name` that carries one additional
/// commit.
///
/// The extra commit writes `branch.txt` so the branch diverges from the
/// default at a distinct SHA. Leaves HEAD on the default branch.
///
/// # Panics
///
/// Panics on any git failure.
pub fn init_git_repo_with_branches(path: &Path, branch_name: &str) {
    init_git_repo_with_seed(path);

    let default_branch = run_git_output(path, &["rev-parse", "--abbrev-ref", "HEAD"]);

    run_git(path, &["branch", branch_name]);
    run_git(path, &["checkout", branch_name]);

    std::fs::write(path.join("branch.txt"), branch_name.as_bytes()).expect("write branch.txt");

    run_git(path, &["add", "branch.txt"]);
    run_git(path, &["-c", "commit.gpgsign=false", "commit", "-m", branch_name]);
    run_git(path, &["checkout", &default_branch]);
}

pub fn git_head_sha(repo_path: &Path, reference: &str) -> String {
    run_git_output(repo_path, &["rev-parse", reference])
}

pub fn git_branches_matching(repo_path: &Path, prefix: &str) -> Vec<String> {
    let output = run_git_output(repo_path, &["branch", "--list", &format!("{prefix}*")]);
    output
        .lines()
        .map(|line| line.trim().trim_start_matches("* ").to_string())
        .filter(|name| !name.is_empty())
        .collect()
}

fn run_git(dir: &Path, args: &[&str]) {
    let output = Command::new("git")
        .args(["-C"])
        .arg(dir)
        .args(args)
        .output()
        .expect("run git command");

    if !output.status.success() {
        panic!(
            "git {:?} failed: {}",
            args,
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

fn run_git_output(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(["-C"])
        .arg(dir)
        .args(args)
        .output()
        .expect("run git command");

    if !output.status.success() {
        panic!(
            "git {:?} failed: {}",
            args,
            String::from_utf8_lossy(&output.stderr)
        );
    }

    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

/// Run a closure inside an isolated Harness filesystem scope.
///
/// Tests often set `XDG_DATA_HOME` to a temp dir but still accidentally see a
/// live Harness Monitor daemon because daemon discovery falls back to the real
/// account home for the app-group container path. This helper redirects both
/// Harness data and host-home discovery into the temp tree and clears daemon
/// root overrides so unit and integration tests cannot touch live app state.
///
/// # Panics
///
/// Panics if the isolated home directory cannot be created.
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
