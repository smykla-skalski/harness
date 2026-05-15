use std::collections::{BTreeMap, BTreeSet};

use octocrab::models;
use octocrab::{Error as OctocrabError, Octocrab};
use reqwest::StatusCode;
use serde::Deserialize;
use serde_json::json;

use super::config::GitHubProjectConfig;
use super::evidence::{
    GitHubBranchProtectionEvidence, GitHubCheckConclusion, GitHubCheckEvidence, GitHubCheckStatus,
    GitHubReviewEvidence, GitHubReviewState,
};

pub(super) async fn combined_status_for_sha(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    sha: &str,
) -> Result<models::CombinedStatus, OctocrabError> {
    let route = format!(
        "/repos/{}/{}/commits/{}/status",
        config.owner,
        config.repo,
        encode_path_segment(sha)
    );
    client.get(route, None::<&()>).await
}

pub(super) async fn branch_protection_evidence(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    pull_request: &models::pulls::PullRequest,
) -> Result<GitHubBranchProtectionEvidence, OctocrabError> {
    let branch = branch_details(client, config, &pull_request.base.ref_field).await?;
    let status_checks =
        required_status_checks(client, config, &pull_request.base.ref_field).await?;
    let rules = branch_rules(client, config, &pull_request.base.ref_field).await?;
    let required_checks = required_check_names(status_checks.as_ref(), &rules);
    Ok(GitHubBranchProtectionEvidence {
        enabled: branch.as_ref().is_some_and(|branch| branch.protected)
            || status_checks.is_some()
            || !rules.is_empty(),
        merge_allowed: pull_request_merge_allowed(pull_request),
        required_checks,
    })
}

async fn branch_details(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    branch: &str,
) -> Result<Option<models::repos::Branch>, OctocrabError> {
    optional_get(
        client,
        format!(
            "/repos/{}/{}/branches/{}",
            config.owner,
            config.repo,
            encode_path_segment(branch)
        ),
    )
    .await
}

async fn required_status_checks(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    branch: &str,
) -> Result<Option<GitHubRequiredStatusChecksResponse>, OctocrabError> {
    optional_get(
        client,
        format!(
            "/repos/{}/{}/branches/{}/protection/required_status_checks",
            config.owner,
            config.repo,
            encode_path_segment(branch)
        ),
    )
    .await
}

async fn branch_rules(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    branch: &str,
) -> Result<Vec<GitHubBranchRuleResponse>, OctocrabError> {
    optional_get(
        client,
        format!(
            "/repos/{}/{}/rules/branches/{}",
            config.owner,
            config.repo,
            encode_path_segment(branch)
        ),
    )
    .await
    .map(Option::unwrap_or_default)
}

pub(super) async fn check_runs_for_ref(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    git_ref: &str,
) -> Result<Vec<GitHubCheckRunResponse>, OctocrabError> {
    let mut check_runs = Vec::new();
    let mut page = 1_u32;
    loop {
        let response: GitHubCheckRunsResponse = client
            .get(
                format!(
                    "/repos/{}/{}/commits/{}/check-runs?per_page=100&page={page}",
                    config.owner,
                    config.repo,
                    encode_path_segment(git_ref)
                ),
                None::<&()>,
            )
            .await?;
        let total_count = response.total_count;
        if response.check_runs.is_empty() {
            break;
        }
        check_runs.extend(response.check_runs);
        if check_runs.len() >= total_count {
            break;
        }
        page += 1;
    }
    Ok(check_runs)
}

pub(super) async fn review_thread_summary(
    client: &Octocrab,
    config: &GitHubProjectConfig,
    pull_request: &models::pulls::PullRequest,
) -> Result<GitHubReviewThreadSummary, OctocrabError> {
    if pull_request.review_comments == 0 {
        return Ok(GitHubReviewThreadSummary::default());
    }

    let mut summary = GitHubReviewThreadSummary::default();
    let mut cursor = None;
    loop {
        let response: GitHubReviewThreadsResponse = client
            .graphql(&json!({
                "query": REVIEW_THREADS_QUERY,
                "variables": {
                    "owner": config.owner.as_str(),
                    "repo": config.repo.as_str(),
                    "number": pull_request.number,
                    "after": cursor.as_deref(),
                },
            }))
            .await?;
        let Some(pull_request) = response.repository.and_then(|repo| repo.pull_request) else {
            break;
        };
        summary.add_threads(pull_request.review_threads.nodes);
        if !pull_request.review_threads.page_info.has_next_page {
            break;
        }
        cursor = pull_request.review_threads.page_info.end_cursor;
    }
    Ok(summary)
}

async fn optional_get<T: for<'de> Deserialize<'de>>(
    client: &Octocrab,
    route: String,
) -> Result<Option<T>, OctocrabError> {
    match client.get(route, None::<&()>).await {
        Ok(value) => Ok(Some(value)),
        Err(error) if github_not_found(&error) => Ok(None),
        Err(error) => Err(error),
    }
}

pub(super) fn merge_checks(
    statuses: Vec<models::Status>,
    check_runs: Vec<GitHubCheckRunResponse>,
) -> Vec<GitHubCheckEvidence> {
    let mut merged = BTreeMap::new();
    for status in statuses {
        let Some(name) = status.context else {
            continue;
        };
        merged.insert(name.clone(), status_evidence(name, status.state));
    }
    for check_run in check_runs {
        merged.insert(check_run.name.clone(), check_run.into_evidence());
    }
    merged.into_values().collect()
}

pub(super) fn merge_reviews(
    mut reviews: Vec<models::pulls::Review>,
    threads: &GitHubReviewThreadSummary,
) -> Vec<GitHubReviewEvidence> {
    reviews.sort_by_key(|review| review.submitted_at);
    merge_review_rollups(
        reviews.iter().filter_map(review_rollup),
        &threads.unresolved_by_reviewer,
    )
}

fn merge_review_rollups(
    reviews: impl IntoIterator<Item = GitHubReviewRollup>,
    unresolved_threads: &BTreeMap<String, u32>,
) -> Vec<GitHubReviewEvidence> {
    let mut merged: BTreeMap<String, GitHubReviewEvidence> = BTreeMap::new();
    for review in reviews {
        let unresolved_requested_changes = match review.state {
            GitHubReviewState::ChangesRequested => unresolved_threads
                .get(&review.reviewer)
                .copied()
                .unwrap_or(1),
            _ => unresolved_threads
                .get(&review.reviewer)
                .copied()
                .unwrap_or(0),
        };
        merged.insert(
            review.reviewer.clone(),
            GitHubReviewEvidence {
                reviewer: review.reviewer,
                state: review.state,
                unresolved_requested_changes,
            },
        );
    }
    merged.into_values().collect()
}

fn review_rollup(review: &models::pulls::Review) -> Option<GitHubReviewRollup> {
    let reviewer = review.user.as_ref().map(|user| user.login.clone())?;
    let state = match review.state? {
        models::pulls::ReviewState::Approved => GitHubReviewState::Approved,
        models::pulls::ReviewState::ChangesRequested => GitHubReviewState::ChangesRequested,
        models::pulls::ReviewState::Commented => GitHubReviewState::Commented,
        models::pulls::ReviewState::Dismissed => GitHubReviewState::Dismissed,
        _ => return None,
    };
    Some(GitHubReviewRollup { reviewer, state })
}

fn status_evidence(name: String, state: models::StatusState) -> GitHubCheckEvidence {
    GitHubCheckEvidence {
        name,
        status: match state {
            models::StatusState::Failure
            | models::StatusState::Error
            | models::StatusState::Success => GitHubCheckStatus::Completed,
            _ => GitHubCheckStatus::InProgress,
        },
        conclusion: Some(match state {
            models::StatusState::Success => GitHubCheckConclusion::Success,
            models::StatusState::Failure | models::StatusState::Error => {
                GitHubCheckConclusion::Failure
            }
            _ => GitHubCheckConclusion::ActionRequired,
        }),
    }
}

fn required_check_names(
    status_checks: Option<&GitHubRequiredStatusChecksResponse>,
    rules: &[GitHubBranchRuleResponse],
) -> Vec<String> {
    let mut required = BTreeSet::new();
    if let Some(status_checks) = status_checks {
        for context in &status_checks.contexts {
            required.insert(context.clone());
        }
        for check in &status_checks.checks {
            required.insert(check.context.clone());
        }
    }
    for rule in rules {
        if rule.rule_type != "required_status_checks" {
            continue;
        }
        let Some(parameters) = rule.parameters.as_ref() else {
            continue;
        };
        for check in &parameters.required_status_checks {
            required.insert(check.context.clone());
        }
    }
    required.into_iter().collect()
}

fn pull_request_merge_allowed(pull_request: &models::pulls::PullRequest) -> bool {
    pull_request.mergeable.unwrap_or(false)
        && !matches!(
            pull_request.mergeable_state,
            Some(
                models::pulls::MergeableState::Behind
                    | models::pulls::MergeableState::Blocked
                    | models::pulls::MergeableState::Dirty
                    | models::pulls::MergeableState::Draft
                    | models::pulls::MergeableState::Unknown
            )
        )
}

fn github_not_found(error: &OctocrabError) -> bool {
    matches!(
        error,
        OctocrabError::GitHub { source, .. } if source.status_code == StatusCode::NOT_FOUND
    )
}

fn encode_path_segment(value: &str) -> String {
    value
        .bytes()
        .flat_map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                vec![char::from(byte)]
            }
            _ => format!("%{byte:02X}").chars().collect(),
        })
        .collect()
}

const REVIEW_THREADS_QUERY: &str = r"
query($owner: String!, $repo: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $after) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          isResolved
          comments(first: 1) {
            nodes {
              author {
                login
              }
            }
          }
        }
      }
    }
  }
}
";

#[derive(Debug)]
struct GitHubReviewRollup {
    reviewer: String,
    state: GitHubReviewState,
}

#[derive(Debug, Deserialize)]
pub(super) struct GitHubCheckRunsResponse {
    total_count: usize,
    check_runs: Vec<GitHubCheckRunResponse>,
}

#[derive(Debug, Deserialize)]
pub(super) struct GitHubCheckRunResponse {
    name: String,
    status: String,
    conclusion: Option<String>,
}

impl GitHubCheckRunResponse {
    fn into_evidence(self) -> GitHubCheckEvidence {
        GitHubCheckEvidence {
            name: self.name,
            status: match self.status.as_str() {
                "queued" | "requested" | "waiting" | "pending" => GitHubCheckStatus::Queued,
                "completed" => GitHubCheckStatus::Completed,
                _ => GitHubCheckStatus::InProgress,
            },
            conclusion: self
                .conclusion
                .as_deref()
                .map(|conclusion| match conclusion {
                    "success" => GitHubCheckConclusion::Success,
                    "neutral" => GitHubCheckConclusion::Neutral,
                    "cancelled" => GitHubCheckConclusion::Cancelled,
                    "skipped" => GitHubCheckConclusion::Skipped,
                    "timed_out" => GitHubCheckConclusion::TimedOut,
                    "action_required" => GitHubCheckConclusion::ActionRequired,
                    _ => GitHubCheckConclusion::Failure,
                }),
        }
    }
}

#[derive(Debug, Deserialize)]
struct GitHubRequiredStatusChecksResponse {
    #[serde(default)]
    contexts: Vec<String>,
    #[serde(default)]
    checks: Vec<GitHubRequiredCheckResponse>,
}

#[derive(Debug, Deserialize)]
struct GitHubRequiredCheckResponse {
    context: String,
}

#[derive(Debug, Deserialize)]
struct GitHubBranchRuleResponse {
    #[serde(rename = "type")]
    rule_type: String,
    parameters: Option<GitHubBranchRuleParameters>,
}

#[derive(Debug, Deserialize)]
struct GitHubBranchRuleParameters {
    #[serde(default)]
    required_status_checks: Vec<GitHubRuleStatusCheck>,
}

#[derive(Debug, Deserialize)]
struct GitHubRuleStatusCheck {
    context: String,
}

#[derive(Debug, Default)]
pub(super) struct GitHubReviewThreadSummary {
    unresolved_by_reviewer: BTreeMap<String, u32>,
}

impl GitHubReviewThreadSummary {
    fn add_threads(&mut self, threads: Vec<GitHubReviewThreadNode>) {
        for thread in threads {
            if thread.is_resolved {
                continue;
            }
            let Some(login) = thread
                .comments
                .nodes
                .first()
                .and_then(|comment| comment.author.as_ref())
                .map(|author| author.login.clone())
            else {
                continue;
            };
            *self.unresolved_by_reviewer.entry(login).or_default() += 1;
        }
    }
}

#[derive(Debug, Deserialize)]
struct GitHubReviewThreadsResponse {
    repository: Option<GitHubReviewThreadsRepository>,
}

#[derive(Debug, Deserialize)]
struct GitHubReviewThreadsRepository {
    #[serde(rename = "pullRequest")]
    pull_request: Option<GitHubReviewThreadsPullRequest>,
}

#[derive(Debug, Deserialize)]
struct GitHubReviewThreadsPullRequest {
    #[serde(rename = "reviewThreads")]
    review_threads: GitHubGraphqlConnection<GitHubReviewThreadNode>,
}

#[derive(Debug, Deserialize)]
struct GitHubGraphqlConnection<T> {
    #[serde(rename = "pageInfo")]
    page_info: GitHubGraphqlPageInfo,
    nodes: Vec<T>,
}

#[derive(Debug, Deserialize)]
struct GitHubGraphqlPageInfo {
    #[serde(rename = "hasNextPage")]
    has_next_page: bool,
    #[serde(rename = "endCursor")]
    end_cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GitHubReviewThreadNode {
    #[serde(rename = "isResolved")]
    is_resolved: bool,
    comments: GitHubGraphqlCommentConnection,
}

#[derive(Debug, Deserialize)]
struct GitHubGraphqlCommentConnection {
    nodes: Vec<GitHubReviewThreadComment>,
}

#[derive(Debug, Deserialize)]
struct GitHubReviewThreadComment {
    author: Option<GitHubGraphqlActor>,
}

#[derive(Debug, Deserialize)]
struct GitHubGraphqlActor {
    login: String,
}

#[cfg(test)]
mod tests;
