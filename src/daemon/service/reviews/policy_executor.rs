use std::path::PathBuf;

use async_trait::async_trait;

use crate::daemon::service::reviews::token::{github_token, missing_token_error};
use crate::errors::CliError;
use crate::reviews::policy::{ReviewsPolicyActionExecutor, ReviewsPolicyProvider};
use crate::reviews::{ReviewTarget, ReviewsGitHubClient};
use crate::task_board::github::GitHubMergeMethod;
use crate::task_board::policy_runtime::handoff::HandoffPolicyProvider;
use crate::task_board::policy_runtime::notification::NotificationPolicyProvider;
use crate::task_board::policy_runtime::providers::PolicyProviderRegistry;
use crate::task_board::policy_runtime::task_creation::TaskCreationPolicyProvider;

pub(crate) struct DaemonReviewsPolicyExecutor {
    client: ReviewsGitHubClient,
}

#[async_trait]
impl ReviewsPolicyActionExecutor for DaemonReviewsPolicyExecutor {
    async fn approve(&self, target: &ReviewTarget) -> Result<(), CliError> {
        self.client.policy_approve(target).await
    }

    async fn merge(
        &self,
        target: &ReviewTarget,
        method: GitHubMergeMethod,
    ) -> Result<(), CliError> {
        self.client.policy_merge(target, method).await
    }
}

pub(crate) fn daemon_policy_executor(
    repository: &str,
) -> Result<DaemonReviewsPolicyExecutor, CliError> {
    let token = github_token(Some(repository))
        .or_else(|| github_token(None))
        .ok_or_else(|| missing_token_error(Some(repository)))?;
    Ok(DaemonReviewsPolicyExecutor {
        client: ReviewsGitHubClient::new(&token)?,
    })
}

/// Build the production policy provider registry: the reviews action provider
/// plus the domain-agnostic handoff, notification, and task-board providers. A
/// workflow that mixes reviews actions and orchestration steps dispatches each
/// step to the right domain through the same runtime, and every non-reviews
/// provider writes a durable side effect under `root`.
pub(crate) fn build_policy_provider_registry<E>(
    executor: E,
    root: PathBuf,
) -> PolicyProviderRegistry
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let mut providers = PolicyProviderRegistry::default();
    providers.register(ReviewsPolicyProvider::new(executor));
    providers.register(HandoffPolicyProvider::new(root.clone()));
    providers.register(NotificationPolicyProvider::new(root.clone()));
    providers.register(TaskCreationPolicyProvider::new(root));
    providers
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::policy_runtime::handoff::{HANDOFF_ACTION_KEY, HANDOFF_PROVIDER};
    use crate::task_board::policy_runtime::models::{
        PolicyActionDescriptor, PolicyRunSubject, PolicyRunTrigger,
    };
    use crate::task_board::policy_runtime::notification::{
        NOTIFICATION_ACTION_KEY, NOTIFICATION_PROVIDER,
    };
    use crate::task_board::policy_runtime::providers::PolicyExecutionContext;
    use crate::task_board::policy_runtime::task_creation::{
        TASK_CREATION_ACTION_KEY, TASK_CREATION_PROVIDER,
    };
    use tempfile::tempdir;

    #[derive(Clone)]
    struct NoopExecutor;

    #[async_trait]
    impl ReviewsPolicyActionExecutor for NoopExecutor {
        async fn approve(&self, _target: &ReviewTarget) -> Result<(), CliError> {
            Ok(())
        }

        async fn merge(
            &self,
            _target: &ReviewTarget,
            _method: GitHubMergeMethod,
        ) -> Result<(), CliError> {
            Ok(())
        }
    }

    fn execution_context() -> PolicyExecutionContext {
        PolicyExecutionContext {
            workflow_id: "reviews_auto".to_owned(),
            subject: PolicyRunSubject::review_pr("owner/repo#1"),
            trigger: PolicyRunTrigger::Background,
        }
    }

    #[tokio::test]
    async fn production_registry_dispatches_handoff_to_the_handoff_provider() {
        let dir = tempdir().expect("tempdir");
        let registry = build_policy_provider_registry(NoopExecutor, dir.path().to_path_buf());
        let action = PolicyActionDescriptor {
            provider: HANDOFF_PROVIDER.to_owned(),
            action_key: HANDOFF_ACTION_KEY.to_owned(),
            payload: Some(serde_json::json!({ "handoff_key": "next-handler" })),
        };
        let execution = registry
            .execute(&action, &execution_context())
            .await
            .expect("dispatch handoff in production registry");
        assert_eq!(execution.action_key, HANDOFF_ACTION_KEY);
    }

    #[tokio::test]
    async fn production_registry_still_routes_reviews_actions_to_the_reviews_provider() {
        let dir = tempdir().expect("tempdir");
        let registry = build_policy_provider_registry(NoopExecutor, dir.path().to_path_buf());
        let action = PolicyActionDescriptor {
            provider: "reviews".to_owned(),
            action_key: "reviews.approve".to_owned(),
            payload: None,
        };
        let error = registry
            .execute(&action, &execution_context())
            .await
            .expect_err("reviews action without payload is rejected by the reviews provider");
        let message = error.to_string();
        assert!(
            !message.contains("no policy action provider registered"),
            "reviews provider must be registered, got: {message}"
        );
    }

    #[tokio::test]
    async fn production_registry_dispatches_all_four_domains() {
        let dir = tempdir().expect("tempdir");
        let registry = build_policy_provider_registry(NoopExecutor, dir.path().to_path_buf());

        let handoff = PolicyActionDescriptor {
            provider: HANDOFF_PROVIDER.to_owned(),
            action_key: HANDOFF_ACTION_KEY.to_owned(),
            payload: Some(serde_json::json!({ "handoff_key": "next-handler" })),
        };
        let notification = PolicyActionDescriptor {
            provider: NOTIFICATION_PROVIDER.to_owned(),
            action_key: NOTIFICATION_ACTION_KEY.to_owned(),
            payload: Some(serde_json::json!({ "channel": "ops", "message": "merged" })),
        };
        let task_creation = PolicyActionDescriptor {
            provider: TASK_CREATION_PROVIDER.to_owned(),
            action_key: TASK_CREATION_ACTION_KEY.to_owned(),
            payload: Some(serde_json::json!({ "title": "Follow up" })),
        };
        let reviews = PolicyActionDescriptor {
            provider: "reviews".to_owned(),
            action_key: "reviews.approve".to_owned(),
            payload: None,
        };

        for action in [&handoff, &notification, &task_creation, &reviews] {
            let outcome = registry.execute(action, &execution_context()).await;
            let message = outcome
                .err()
                .map(|error| error.to_string())
                .unwrap_or_default();
            assert!(
                !message.contains("no policy action provider registered"),
                "domain '{}' must be registered, got: {message}",
                action.provider
            );
        }
    }
}
