use std::collections::BTreeSet;
use std::{env, fmt};

use crate::errors::CliError;

use super::{
    ExternalProvider, GH_TOKEN_ENV, GITHUB_REPOSITORY_ENV, HARNESS_GITHUB_REPOSITORY_ENV,
    HARNESS_GITHUB_TOKEN_ENV, HARNESS_TODOIST_TOKEN_ENV, missing_token_error,
};

#[derive(Clone, Default, PartialEq, Eq)]
pub struct ExternalSyncConfig {
    pub github_token: Option<String>,
    pub github_repository: Option<String>,
    pub github_inbox_repositories: Vec<String>,
    pub github_import_labels: Vec<String>,
    pub todoist_token: Option<String>,
    pub todoist_import_project_ids: Vec<String>,
}

impl ExternalSyncConfig {
    #[must_use]
    pub fn from_env() -> Self {
        Self {
            github_token: first_present_env(&[HARNESS_GITHUB_TOKEN_ENV, GH_TOKEN_ENV]),
            github_repository: first_present_env(&[
                HARNESS_GITHUB_REPOSITORY_ENV,
                GITHUB_REPOSITORY_ENV,
            ]),
            github_inbox_repositories: Vec::new(),
            github_import_labels: Vec::new(),
            todoist_token: first_present_env(&[HARNESS_TODOIST_TOKEN_ENV]),
            todoist_import_project_ids: Vec::new(),
        }
    }

    #[must_use]
    pub fn token_for(&self, provider: ExternalProvider) -> Option<&str> {
        match provider {
            ExternalProvider::GitHub => self.github_token.as_deref(),
            ExternalProvider::Todoist => self.todoist_token.as_deref(),
        }
    }

    #[must_use]
    pub fn github_repository(&self) -> Option<&str> {
        self.github_repository
            .as_deref()
            .map(str::trim)
            .filter(|repository| !repository.is_empty())
    }

    #[must_use]
    pub fn github_inbox_repositories(&self) -> &[String] {
        &self.github_inbox_repositories
    }

    #[must_use]
    pub fn github_import_labels(&self) -> &[String] {
        &self.github_import_labels
    }

    #[must_use]
    pub fn todoist_import_project_ids(&self) -> &[String] {
        &self.todoist_import_project_ids
    }

    #[must_use]
    pub fn with_github_token_override(mut self, token: Option<&str>) -> Self {
        self.github_token = token
            .map(str::trim)
            .filter(|token| !token.is_empty())
            .map(ToOwned::to_owned);
        self
    }

    #[must_use]
    pub fn with_todoist_token_override(mut self, token: Option<&str>) -> Self {
        self.todoist_token = token
            .map(str::trim)
            .filter(|token| !token.is_empty())
            .map(ToOwned::to_owned);
        self
    }

    #[must_use]
    pub fn with_github_repository_override(mut self, repository: Option<&str>) -> Self {
        self.github_repository = repository
            .map(str::trim)
            .filter(|repository| !repository.is_empty())
            .map(ToOwned::to_owned);
        self
    }

    #[must_use]
    pub fn with_github_repository_fallback(mut self, repository: Option<&str>) -> Self {
        if self.github_repository().is_none() {
            self.github_repository = repository
                .map(str::trim)
                .filter(|repository| !repository.is_empty())
                .map(ToOwned::to_owned);
        }
        self
    }

    #[must_use]
    pub fn with_github_inbox_repositories_override(mut self, repositories: &[String]) -> Self {
        self.github_inbox_repositories = repositories
            .iter()
            .map(String::as_str)
            .map(str::trim)
            .filter(|repository| !repository.is_empty())
            .map(ToOwned::to_owned)
            .collect();
        self
    }

    #[must_use]
    pub fn with_github_import_labels_override(mut self, labels: &[String]) -> Self {
        self.github_import_labels = normalize_string_list(labels);
        self
    }

    #[must_use]
    pub fn with_todoist_import_project_ids_override(mut self, project_ids: &[String]) -> Self {
        self.todoist_import_project_ids = normalize_string_list(project_ids);
        self
    }

    /// Return the configured token for a provider.
    ///
    /// # Errors
    /// Returns an error when the provider token is missing or empty.
    pub fn require_token(&self, provider: ExternalProvider) -> Result<&str, CliError> {
        self.token_for(provider)
            .filter(|token| !token.trim().is_empty())
            .map(str::trim)
            .ok_or_else(|| missing_token_error(provider))
    }
}

impl fmt::Debug for ExternalSyncConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ExternalSyncConfig")
            .field("github_token", &redacted(self.github_token.as_deref()))
            .field("github_repository", &self.github_repository)
            .field("github_inbox_repositories", &self.github_inbox_repositories)
            .field("github_import_labels", &self.github_import_labels)
            .field("todoist_token", &redacted(self.todoist_token.as_deref()))
            .field(
                "todoist_import_project_ids",
                &self.todoist_import_project_ids,
            )
            .finish()
    }
}

fn normalize_string_list(values: &[String]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::with_capacity(values.len());
    for value in values {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            continue;
        }
        if seen.insert(trimmed.to_owned()) {
            out.push(trimmed.to_owned());
        }
    }
    out
}

fn first_present_env(names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| read_token_env(name))
}

fn read_token_env(name: &str) -> Option<String> {
    let value = env::var(name).ok()?;
    let token = value.trim();
    (!token.is_empty()).then(|| token.to_owned())
}

fn redacted(value: Option<&str>) -> &'static str {
    match value {
        Some(token) if !token.trim().is_empty() => "<redacted>",
        _ => "<unset>",
    }
}
