use std::collections::{BTreeSet, hash_map::DefaultHasher};
use std::hash::{Hash, Hasher};
use std::path::Path;
use std::process::Command;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use reqwest::header::{ACCEPT, USER_AGENT};
use serde_json::{Value, json};

pub(super) struct GitHubClient {
    client: reqwest::blocking::Client,
    token: String,
}

impl GitHubClient {
    pub(super) fn new(token: &str) -> Self {
        Self {
            client: reqwest::blocking::Client::new(),
            token: token.to_owned(),
        }
    }

    fn get(&self, path: &str) -> Value {
        let response = self
            .client
            .get(format!("https://api.github.com{path}"))
            .bearer_auth(&self.token)
            .header(USER_AGENT, "harness-live-report-only-review")
            .header(ACCEPT, "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .timeout(Duration::from_secs(30))
            .send()
            .expect("stage=github: request");
        let status = response.status();
        let text = response.text().expect("stage=github: response");
        assert!(status.is_success(), "stage=github: HTTP {status}: {text}");
        serde_json::from_str(&text).expect("stage=github: decode response")
    }

    fn get_pages(&self, path: &str) -> Value {
        let mut items = Vec::new();
        for page in 1.. {
            let response = self.get(&format!("{path}?per_page=100&page={page}"));
            let mut page_items = response
                .as_array()
                .expect("stage=github: expected paginated array")
                .clone();
            let complete = page_items.len() < 100;
            items.append(&mut page_items);
            if complete {
                break;
            }
        }
        Value::Array(items)
    }
}

#[derive(Debug)]
pub(super) struct LiveReviewTarget {
    pub(super) repository: String,
    pub(super) number: u64,
    pub(super) url: String,
    pub(super) head: String,
}

impl LiveReviewTarget {
    pub(super) fn from_env(github: &GitHubClient) -> Self {
        let input_url = std::env::var("HARNESS_LIVE_REVIEW_PR_URL")
            .expect("HARNESS_LIVE_REVIEW_PR_URL must identify the open pull request to review");
        let (repository, number) = parse_pr_url(&input_url);
        let pull = github.get(&format!("/repos/{repository}/pulls/{number}"));
        assert_eq!(pull["state"], "open", "stage=github: PR must be open");
        let head = pull
            .pointer("/head/sha")
            .and_then(Value::as_str)
            .expect("stage=github: PR head SHA")
            .to_owned();
        Self {
            url: format!("https://github.com/{repository}/pull/{number}"),
            repository,
            number,
            head,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct GitHubSnapshot {
    core: String,
    viewer_issue_comments: BTreeSet<String>,
    viewer_reviews: BTreeSet<String>,
    viewer_review_comments: BTreeSet<String>,
}

impl GitHubSnapshot {
    pub(super) fn capture(target: &LiveReviewTarget, github: &GitHubClient) -> Self {
        let viewer = github.get("/user")["login"]
            .as_str()
            .expect("stage=github: authenticated viewer login")
            .to_owned();
        let pull = github.get(&format!(
            "/repos/{}/pulls/{}",
            target.repository, target.number
        ));
        let core = serde_json::to_string(&json!({
            "head": pull.pointer("/head/sha"),
            "state": pull["state"],
            "merged_at": pull["merged_at"],
            "title": pull["title"],
            "body": pull["body"],
        }))
        .expect("stage=github: encode PR core state");
        assert_eq!(
            pull.pointer("/head/sha").and_then(Value::as_str),
            Some(target.head.as_str()),
            "stage=github: PR head changed during live review"
        );
        let comments = github.get_pages(&format!(
            "/repos/{}/issues/{}/comments",
            target.repository, target.number
        ));
        let reviews = github.get_pages(&format!(
            "/repos/{}/pulls/{}/reviews",
            target.repository, target.number
        ));
        let review_comments = github.get_pages(&format!(
            "/repos/{}/pulls/{}/comments",
            target.repository, target.number
        ));
        Self {
            core,
            viewer_issue_comments: viewer_activity(&comments, &viewer),
            viewer_reviews: viewer_activity(&reviews, &viewer),
            viewer_review_comments: viewer_activity(&review_comments, &viewer),
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct LocalRepositorySnapshot {
    status: String,
    head: String,
    head_state: String,
    refs_fingerprint: u64,
    fetch_head: String,
}

impl LocalRepositorySnapshot {
    pub(super) fn capture(project: &Path) -> Self {
        Self {
            status: git_output(
                project,
                &["status", "--porcelain=v1", "--untracked-files=all"],
            ),
            head: git_output(project, &["rev-parse", "HEAD"]),
            head_state: git_metadata(project, "HEAD"),
            refs_fingerprint: stable_ref_fingerprint(project),
            fetch_head: git_metadata(project, "FETCH_HEAD"),
        }
    }
}

fn stable_ref_fingerprint(project: &Path) -> u64 {
    let refs = git_output(
        project,
        &["for-each-ref", "--format=%(refname) %(objectname)"],
    );
    stable_ref_fingerprint_from(&refs)
}

fn stable_ref_fingerprint_from(refs: &str) -> u64 {
    let stable_refs = refs
        .lines()
        // Session startup owns this isolated worktree namespace; report-only
        // guarantees apply to the supplied checkout and all other refs.
        .filter(|line| !line.starts_with("refs/heads/harness/"))
        .collect::<Vec<_>>();
    let mut hasher = DefaultHasher::new();
    stable_refs.hash(&mut hasher);
    hasher.finish()
}

fn git_metadata(project: &Path, name: &str) -> String {
    let path = git_output(project, &["rev-parse", "--git-path", name]);
    std::fs::read_to_string(project.join(path))
        .unwrap_or_else(|error| panic!("stage=mutation_check: read {name}: {error}"))
}

pub(super) fn prepare_review_checkout(
    target: &LiveReviewTarget,
    project: &Path,
    github_token: &str,
) {
    let source = std::env::var("HARNESS_LIVE_REVIEW_SOURCE_REPO")
        .expect("HARNESS_LIVE_REVIEW_SOURCE_REPO must identify the complete local repository");
    run_git(
        None,
        &[
            "clone",
            "--shared",
            "--no-checkout",
            &source,
            project.to_str().expect("stage=fixture: UTF-8 project path"),
        ],
    );
    let github_url = format!("https://github.com/{}.git", target.repository);
    let pull_ref = format!("refs/pull/{}/head", target.number);
    let remote_ref = "refs/remotes/origin/live-review-head";
    let fetch_refspec = format!("+{pull_ref}:{remote_ref}");
    run_authenticated_git(
        Some(project),
        &["fetch", "--no-tags", &github_url, &fetch_refspec],
        github_token,
    );
    run_git(
        Some(project),
        &["symbolic-ref", "refs/remotes/origin/HEAD", remote_ref],
    );
    run_git(Some(project), &["checkout", "--detach", &target.head]);
    let head = git_output(project, &["rev-parse", "HEAD"]);
    assert_eq!(head, target.head, "stage=fixture: checkout wrong PR head");
}

fn parse_pr_url(url: &str) -> (String, u64) {
    let path = url
        .strip_prefix("https://github.com/")
        .expect("HARNESS_LIVE_REVIEW_PR_URL must use https://github.com/");
    let path = path.split(['?', '#']).next().expect("nonempty PR URL");
    let components: Vec<&str> = path.trim_end_matches('/').split('/').collect();
    assert_eq!(
        components.len(),
        4,
        "HARNESS_LIVE_REVIEW_PR_URL must identify one pull request"
    );
    assert_eq!(components[2], "pull");
    let number = components[3]
        .parse()
        .expect("HARNESS_LIVE_REVIEW_PR_URL pull number");
    (format!("{}/{}", components[0], components[1]), number)
}

fn viewer_activity(items: &Value, viewer: &str) -> BTreeSet<String> {
    items
        .as_array()
        .expect("stage=github: expected array")
        .iter()
        .filter(|item| {
            item.pointer("/user/login")
                .and_then(Value::as_str)
                .is_some_and(|login| login.eq_ignore_ascii_case(viewer))
        })
        .map(|item| serde_json::to_string(item).expect("stage=github: encode viewer activity"))
        .collect()
}

fn run_git(directory: Option<&Path>, args: &[&str]) {
    let mut command = git_command(args);
    if let Some(directory) = directory {
        command.current_dir(directory);
    }
    let output = command.output().expect("stage=fixture: run git");
    assert!(
        output.status.success(),
        "stage=fixture: git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn run_authenticated_git(directory: Option<&Path>, args: &[&str], token: &str) {
    let credentials = BASE64_STANDARD.encode(format!("x-access-token:{token}"));
    let mut command = git_command(args);
    command
        .env("GIT_CONFIG_COUNT", "1")
        .env("GIT_CONFIG_KEY_0", "http.extraHeader")
        .env(
            "GIT_CONFIG_VALUE_0",
            format!("Authorization: Basic {credentials}"),
        );
    if let Some(directory) = directory {
        command.current_dir(directory);
    }
    let output = command
        .output()
        .expect("stage=fixture: run authenticated git");
    assert!(
        output.status.success(),
        "stage=fixture: authenticated git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn git_output(directory: &Path, args: &[&str]) -> String {
    let output = git_command(args)
        .current_dir(directory)
        .output()
        .expect("stage=fixture: run git");
    assert!(output.status.success(), "stage=fixture: {output:?}");
    String::from_utf8(output.stdout)
        .expect("stage=fixture: UTF-8 git output")
        .trim()
        .to_owned()
}

fn git_command(args: &[&str]) -> Command {
    let mut command = Command::new("git");
    command
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_ASKPASS", "true");
    command
}

#[test]
fn pr_url_parser_ignores_query_and_fragment() {
    for suffix in ["?diff=split", "#files_bucket"] {
        let url = format!("https://github.com/acme/widgets/pull/17{suffix}");
        assert_eq!(parse_pr_url(&url), ("acme/widgets".into(), 17));
    }
}

#[test]
fn viewer_activity_preserves_mutable_content() {
    let original = json!([{
        "id": 1,
        "body": "before",
        "updated_at": "2026-07-31T00:00:00Z",
        "user": { "login": "reviewer" }
    }]);
    let edited = json!([{
        "id": 1,
        "body": "after",
        "updated_at": "2026-07-31T00:01:00Z",
        "user": { "login": "reviewer" }
    }]);

    assert_ne!(
        viewer_activity(&original, "reviewer"),
        viewer_activity(&edited, "reviewer")
    );
}

#[test]
fn ref_fingerprint_excludes_only_harness_session_branches() {
    let base = "refs/heads/main aaaaa\nrefs/remotes/origin/main aaaaa";
    let with_session = format!("{base}\nrefs/heads/harness/session-1 aaaaa");
    let with_user_branch = format!("{base}\nrefs/heads/feature/user-change aaaaa");

    assert_eq!(
        stable_ref_fingerprint_from(base),
        stable_ref_fingerprint_from(&with_session)
    );
    assert_ne!(
        stable_ref_fingerprint_from(base),
        stable_ref_fingerprint_from(&with_user_branch)
    );
}
