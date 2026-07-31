use std::collections::BTreeSet;
use std::path::Path;
use std::process::Command;
use std::time::Duration;

use reqwest::header::{ACCEPT, USER_AGENT};
use serde_json::{Value, json};

#[derive(Debug)]
pub(super) struct LiveReviewTarget {
    pub(super) repository: String,
    pub(super) number: u64,
    pub(super) url: String,
    pub(super) head: String,
}

impl LiveReviewTarget {
    pub(super) fn from_env(token: &str) -> Self {
        let url = std::env::var("HARNESS_LIVE_REVIEW_PR_URL")
            .expect("HARNESS_LIVE_REVIEW_PR_URL must identify the open pull request to review");
        let (repository, number) = parse_pr_url(&url);
        let pull = github_get(token, &format!("/repos/{repository}/pulls/{number}"));
        assert_eq!(pull["state"], "open", "stage=github: PR must be open");
        let head = pull
            .pointer("/head/sha")
            .and_then(Value::as_str)
            .expect("stage=github: PR head SHA")
            .to_owned();
        Self {
            repository,
            number,
            url,
            head,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct GitHubSnapshot {
    core: String,
    viewer_comments: BTreeSet<u64>,
    viewer_reviews: BTreeSet<u64>,
}

impl GitHubSnapshot {
    pub(super) fn capture(target: &LiveReviewTarget, token: &str) -> Self {
        let viewer = github_get(token, "/user")["login"]
            .as_str()
            .expect("stage=github: authenticated viewer login")
            .to_owned();
        let pull = github_get(
            token,
            &format!("/repos/{}/pulls/{}", target.repository, target.number),
        );
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
        let comments = github_get_pages(
            token,
            &format!(
                "/repos/{}/issues/{}/comments",
                target.repository, target.number
            ),
        );
        let reviews = github_get_pages(
            token,
            &format!(
                "/repos/{}/pulls/{}/reviews",
                target.repository, target.number
            ),
        );
        Self {
            core,
            viewer_comments: viewer_ids(&comments, &viewer),
            viewer_reviews: viewer_ids(&reviews, &viewer),
        }
    }
}

pub(super) fn prepare_review_checkout(target: &LiveReviewTarget, project: &Path) {
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
    run_git(
        Some(project),
        &["fetch", "--no-tags", &github_url, &fetch_refspec],
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

fn github_get(token: &str, path: &str) -> Value {
    let runtime = tokio::runtime::Runtime::new().expect("stage=github: runtime");
    runtime.block_on(async {
        let response = reqwest::Client::new()
            .get(format!("https://api.github.com{path}"))
            .bearer_auth(token)
            .header(USER_AGENT, "harness-live-report-only-review")
            .header(ACCEPT, "application/vnd.github+json")
            .timeout(Duration::from_secs(30))
            .send()
            .await
            .expect("stage=github: request");
        let status = response.status();
        let text = response.text().await.expect("stage=github: response");
        assert!(status.is_success(), "stage=github: HTTP {status}: {text}");
        serde_json::from_str(&text).expect("stage=github: decode response")
    })
}

fn github_get_pages(token: &str, path: &str) -> Value {
    let mut items = Vec::new();
    for page in 1.. {
        let response = github_get(token, &format!("{path}?per_page=100&page={page}"));
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

fn viewer_ids(items: &Value, viewer: &str) -> BTreeSet<u64> {
    items
        .as_array()
        .expect("stage=github: expected array")
        .iter()
        .filter(|item| {
            item.pointer("/user/login")
                .and_then(Value::as_str)
                .is_some_and(|login| login.eq_ignore_ascii_case(viewer))
        })
        .map(|item| item["id"].as_u64().expect("stage=github: item id"))
        .collect()
}

fn run_git(directory: Option<&Path>, args: &[&str]) {
    let mut command = Command::new("git");
    command.args(args);
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

fn git_output(directory: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(args)
        .current_dir(directory)
        .output()
        .expect("stage=fixture: run git");
    assert!(output.status.success(), "stage=fixture: {output:?}");
    String::from_utf8(output.stdout)
        .expect("stage=fixture: UTF-8 git output")
        .trim()
        .to_owned()
}
