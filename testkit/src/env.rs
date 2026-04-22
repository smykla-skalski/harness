use std::path::Path;

use git2::{BranchType, IndexAddOption, Repository, Signature, build::CheckoutBuilder};

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
    let repo = Repository::init(path).expect("init repo");
    std::fs::write(path.join("README.md"), b"seed\n").expect("seed README");
    stage_path(&repo, Path::new("README.md"));
    commit_head(&repo, "seed");
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
    let repo = Repository::open(path).expect("open repo");
    let default_branch = current_branch_name(&repo);
    let head_commit = repo
        .head()
        .expect("repo head")
        .peel_to_commit()
        .expect("head commit");
    repo.branch(branch_name, &head_commit, false)
        .expect("create branch");
    checkout_branch(&repo, branch_name);
    std::fs::write(path.join("branch.txt"), branch_name.as_bytes()).expect("write branch.txt");
    stage_path(&repo, Path::new("branch.txt"));
    commit_head(&repo, branch_name);
    checkout_branch(&repo, &default_branch);
}

pub fn git_head_sha(repo_path: &Path, reference: &str) -> String {
    let repo = Repository::open(repo_path).expect("open repo");
    repo.revparse_single(reference)
        .expect("resolve reference")
        .id()
        .to_string()
}

pub fn git_branches_matching(repo_path: &Path, prefix: &str) -> Vec<String> {
    let repo = Repository::open(repo_path).expect("open repo");
    repo.branches(Some(BranchType::Local))
        .expect("list branches")
        .filter_map(|branch| {
            let (branch, _) = branch.ok()?;
            let name = branch.name().ok().flatten()?.to_string();
            name.starts_with(prefix).then_some(name)
        })
        .collect()
}

fn stage_path(repo: &Repository, path: &Path) {
    let mut index = repo.index().expect("open index");
    index
        .add_all([path], IndexAddOption::DEFAULT, None)
        .expect("stage path");
    index.write().expect("write index");
}

fn commit_head(repo: &Repository, message: &str) {
    let mut index = repo.index().expect("open index");
    let tree_id = index.write_tree().expect("write tree");
    let tree = repo.find_tree(tree_id).expect("find tree");
    let signature = Signature::now("test", "test@example.com").expect("signature");
    let parents = repo
        .head()
        .ok()
        .and_then(|head| head.peel_to_commit().ok())
        .into_iter()
        .collect::<Vec<_>>();
    let parent_refs = parents.iter().collect::<Vec<_>>();
    repo.commit(
        Some("HEAD"),
        &signature,
        &signature,
        message,
        &tree,
        &parent_refs,
    )
    .expect("create commit");
}

fn current_branch_name(repo: &Repository) -> String {
    repo.head()
        .expect("repo head")
        .shorthand()
        .expect("branch shorthand")
        .to_owned()
}

fn checkout_branch(repo: &Repository, branch_name: &str) {
    repo.set_head(&format!("refs/heads/{branch_name}"))
        .expect("set head");
    repo.checkout_head(Some(CheckoutBuilder::new().force()))
        .expect("checkout head");
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
