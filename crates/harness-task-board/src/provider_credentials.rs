use serde::{Deserialize, Serialize};

use crate::{TaskBoardGitHubRepositoryToken, normalize_repository_slug};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct TaskBoardGitHubCredentialSnapshot {
    #[serde(
        default,
        alias = "global_token",
        skip_serializing_if = "Option::is_none"
    )]
    pub global_token: Option<String>,
    #[serde(
        default,
        alias = "repository_tokens",
        skip_serializing_if = "Vec::is_empty"
    )]
    pub repository_tokens: Vec<TaskBoardGitHubRepositoryToken>,
}

impl TaskBoardGitHubCredentialSnapshot {
    #[must_use]
    pub fn token_configured(&self, repository: Option<&str>) -> bool {
        repository
            .and_then(|repository| normalize_repository_slug(Some(repository)))
            .is_some_and(|repository| {
                self.repository_tokens
                    .iter()
                    .any(|entry| entry.repository == repository && !entry.token.trim().is_empty())
            })
            || repository.is_none()
                && self
                    .global_token
                    .as_deref()
                    .is_some_and(|token| !token.trim().is_empty())
    }

    /// # Errors
    /// Returns an error when the token is blank or the repository slug is invalid.
    pub fn set_token(&mut self, repository: Option<&str>, token: &str) -> Result<(), String> {
        let token = normalized_token(token)?;
        if let Some(repository) = repository {
            let repository = normalize_repository_slug(Some(repository)).ok_or_else(|| {
                format!("invalid repository slug '{repository}', expected owner/repo")
            })?;
            self.repository_tokens
                .retain(|entry| entry.repository != repository);
            self.repository_tokens
                .push(TaskBoardGitHubRepositoryToken { repository, token });
            self.repository_tokens
                .sort_by(|left, right| left.repository.cmp(&right.repository));
        } else {
            self.global_token = Some(token);
        }
        Ok(())
    }

    /// # Errors
    /// Returns an error when the repository slug is invalid.
    pub fn clear_token(&mut self, repository: Option<&str>) -> Result<bool, String> {
        if let Some(repository) = repository {
            let repository = normalize_repository_slug(Some(repository)).ok_or_else(|| {
                format!("invalid repository slug '{repository}', expected owner/repo")
            })?;
            let before = self.repository_tokens.len();
            self.repository_tokens
                .retain(|entry| entry.repository != repository);
            Ok(before != self.repository_tokens.len())
        } else {
            Ok(self.global_token.take().is_some())
        }
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.global_token.is_none() && self.repository_tokens.is_empty()
    }

    #[must_use]
    pub fn is_configured(&self) -> bool {
        self.token_configured(None)
            || self.repository_tokens.iter().any(|entry| {
                normalize_repository_slug(Some(&entry.repository)).is_some()
                    && !entry.token.trim().is_empty()
            })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct TaskBoardOpenRouterCredentialSnapshot {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
}

impl TaskBoardOpenRouterCredentialSnapshot {
    /// # Errors
    /// Returns an error when the token is blank.
    pub fn set_token(&mut self, token: &str) -> Result<(), String> {
        self.token = Some(normalized_token(token)?);
        Ok(())
    }

    pub fn clear_token(&mut self) -> bool {
        self.token.take().is_some()
    }

    #[must_use]
    pub fn is_configured(&self) -> bool {
        self.token
            .as_deref()
            .is_some_and(|token| !token.trim().is_empty())
    }
}

fn normalized_token(token: &str) -> Result<String, String> {
    let token = token.trim().to_owned();
    if token.is_empty() {
        Err("refusing to store an empty secret; use `clear` to remove instead".to_string())
    } else {
        Ok(token)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshots_use_monitor_keychain_json_shape() {
        let github = TaskBoardGitHubCredentialSnapshot {
            global_token: Some("global".into()),
            repository_tokens: vec![TaskBoardGitHubRepositoryToken {
                repository: "owner/repo".into(),
                token: "repo".into(),
            }],
        };
        assert_eq!(
            serde_json::to_value(github).expect("serialize"),
            serde_json::json!({
                "globalToken": "global",
                "repositoryTokens": [{"repository": "owner/repo", "token": "repo"}]
            })
        );
        assert_eq!(
            serde_json::to_value(TaskBoardOpenRouterCredentialSnapshot {
                token: Some("openrouter".into()),
            })
            .expect("serialize"),
            serde_json::json!({"token": "openrouter"})
        );
    }

    #[test]
    fn github_repository_updates_are_normalized_and_preserve_global_token() {
        let mut snapshot = TaskBoardGitHubCredentialSnapshot {
            global_token: Some("global".into()),
            repository_tokens: Vec::new(),
        };
        snapshot
            .set_token(Some("OWNER/REPO"), " repo-token ")
            .expect("set repository token");
        assert!(snapshot.token_configured(Some("owner/repo")));
        assert_eq!(snapshot.global_token.as_deref(), Some("global"));
        assert_eq!(snapshot.repository_tokens[0].token, "repo-token");
    }

    #[test]
    fn clearing_one_github_scope_preserves_the_other() {
        let mut snapshot = TaskBoardGitHubCredentialSnapshot {
            global_token: Some("global".into()),
            repository_tokens: vec![TaskBoardGitHubRepositoryToken {
                repository: "owner/repo".into(),
                token: "repo".into(),
            }],
        };
        assert!(snapshot.clear_token(Some("owner/repo")).expect("clear"));
        assert_eq!(snapshot.global_token.as_deref(), Some("global"));
        assert!(snapshot.repository_tokens.is_empty());
    }
}
