use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitHubProjectConfig {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub owner: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub repo: String,
    #[serde(default, skip_serializing_if = "empty_path")]
    pub checkout_path: PathBuf,
    #[serde(default = "default_branch")]
    pub default_branch: String,
    #[serde(default = "default_branch_prefix")]
    pub branch_prefix: String,
    #[serde(default)]
    pub merge_method: GitHubMergeMethod,
    #[serde(default)]
    pub labels: GitHubAutomationLabels,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub protected_paths: Vec<ProtectedPathRule>,
    #[serde(default, skip_serializing_if = "GitHubRequestedReviewers::is_empty")]
    pub requested_reviewers: GitHubRequestedReviewers,
    #[serde(default)]
    pub enabled_automations: GitHubAutomationToggles,
}

fn default_branch() -> String {
    "main".to_string()
}

fn default_branch_prefix() -> String {
    "c/".to_string()
}

fn empty_path(path: &Path) -> bool {
    path.as_os_str().is_empty()
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitHubMergeMethod {
    #[default]
    Squash,
    Merge,
    Rebase,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitHubAutomationLabels {
    pub managed: String,
    pub auto_merge: String,
    pub needs_human: String,
    pub protected_path: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitHubAutomationToggles {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub enabled: Vec<GitHubAutomation>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitHubRequestedReviewers {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reviewers: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub team_reviewers: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitHubAutomation {
    SyncTaskBoard,
    CreateBranch,
    OpenPullRequest,
    WatchChecks,
    RequestReview,
    AutoMerge,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProtectedPathRule {
    pub pattern: String,
}

impl GitHubProjectConfig {
    #[must_use]
    pub fn new(owner: impl Into<String>, repo: impl Into<String>, checkout_path: PathBuf) -> Self {
        Self {
            owner: owner.into(),
            repo: repo.into(),
            checkout_path,
            default_branch: "main".to_string(),
            branch_prefix: "c/".to_string(),
            merge_method: GitHubMergeMethod::Squash,
            labels: GitHubAutomationLabels::default(),
            protected_paths: Vec::new(),
            requested_reviewers: GitHubRequestedReviewers::default(),
            enabled_automations: GitHubAutomationToggles::default(),
        }
    }

    #[must_use]
    pub fn repository_slug(&self) -> String {
        format!("{}/{}", self.owner, self.repo)
    }

    #[must_use]
    pub fn protects_path(&self, path: &str) -> bool {
        self.protected_paths.iter().any(|rule| rule.matches(path))
    }
}

impl Default for GitHubProjectConfig {
    fn default() -> Self {
        Self {
            owner: String::new(),
            repo: String::new(),
            checkout_path: PathBuf::new(),
            default_branch: default_branch(),
            branch_prefix: default_branch_prefix(),
            merge_method: GitHubMergeMethod::Squash,
            labels: GitHubAutomationLabels::default(),
            protected_paths: Vec::new(),
            requested_reviewers: GitHubRequestedReviewers::default(),
            enabled_automations: GitHubAutomationToggles::default(),
        }
    }
}

impl Default for GitHubAutomationLabels {
    fn default() -> Self {
        Self {
            managed: "harness:managed".to_string(),
            auto_merge: "harness:auto-merge".to_string(),
            needs_human: "harness:needs-human".to_string(),
            protected_path: "harness:protected-path".to_string(),
        }
    }
}

impl Default for GitHubAutomationToggles {
    fn default() -> Self {
        Self {
            enabled: vec![
                GitHubAutomation::SyncTaskBoard,
                GitHubAutomation::CreateBranch,
                GitHubAutomation::OpenPullRequest,
                GitHubAutomation::WatchChecks,
                GitHubAutomation::RequestReview,
            ],
        }
    }
}

impl GitHubAutomationToggles {
    #[must_use]
    pub fn enables(&self, automation: GitHubAutomation) -> bool {
        self.enabled.contains(&automation)
    }
}

impl GitHubRequestedReviewers {
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.reviewers.is_empty() && self.team_reviewers.is_empty()
    }

    #[must_use]
    pub fn normalized_reviewers(&self) -> Vec<String> {
        normalized_entries(&self.reviewers)
    }

    #[must_use]
    pub fn normalized_team_reviewers(&self) -> Vec<String> {
        normalized_entries(&self.team_reviewers)
    }
}

impl ProtectedPathRule {
    #[must_use]
    pub fn new(pattern: impl Into<String>) -> Self {
        Self {
            pattern: normalize_path(pattern.into()),
        }
    }

    #[must_use]
    pub fn matches(&self, path: &str) -> bool {
        let rule = normalize_path(&self.pattern);
        let path = normalize_path(path);
        if rule.is_empty() || path.is_empty() {
            return false;
        }
        path == rule || path.starts_with(&directory_prefix(&rule))
    }
}

fn normalize_path(path: impl AsRef<str>) -> String {
    path.as_ref()
        .trim()
        .trim_start_matches("./")
        .trim_start_matches('/')
        .trim_end_matches('/')
        .to_string()
}

fn directory_prefix(path: &str) -> String {
    format!("{path}/")
}

fn normalized_entries(entries: &[String]) -> Vec<String> {
    let mut normalized = entries
        .iter()
        .filter_map(|entry| {
            let trimmed = entry.trim();
            (!trimmed.is_empty()).then(|| trimmed.to_string())
        })
        .collect::<Vec<_>>();
    normalized.sort();
    normalized.dedup();
    normalized
}
