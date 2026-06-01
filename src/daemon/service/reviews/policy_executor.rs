use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::json;

use crate::daemon::audit_events::{AuditEventDraft, record_audit_result};
use crate::daemon::db::AsyncDaemonDb;
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
    audit_db: Option<Arc<AsyncDaemonDb>>,
}

#[async_trait]
impl ReviewsPolicyActionExecutor for DaemonReviewsPolicyExecutor {
    async fn approve(&self, target: &ReviewTarget) -> Result<(), CliError> {
        let result = self.client.policy_approve(target).await;
        record_reviews_policy_action_audit_result(
            self.audit_db.as_ref(),
            "reviews.approve",
            "Approve pull request from policy workflow",
            target,
            json!({ "source": "policy_runtime" }),
            &result,
        )
        .await;
        result
    }

    async fn merge(
        &self,
        target: &ReviewTarget,
        method: GitHubMergeMethod,
    ) -> Result<(), CliError> {
        let result = self.client.policy_merge(target, method).await;
        record_reviews_policy_action_audit_result(
            self.audit_db.as_ref(),
            "reviews.merge",
            "Merge pull request from policy workflow",
            target,
            json!({
                "source": "policy_runtime",
                "method": format!("{method:?}"),
            }),
            &result,
        )
        .await;
        result
    }
}

pub(crate) fn daemon_policy_executor_with_audit(
    repository: &str,
    audit_db: Option<Arc<AsyncDaemonDb>>,
) -> Result<DaemonReviewsPolicyExecutor, CliError> {
    let token = github_token(Some(repository))
        .or_else(|| github_token(None))
        .ok_or_else(|| missing_token_error(Some(repository)))?;
    Ok(DaemonReviewsPolicyExecutor {
        client: ReviewsGitHubClient::new(&token)?,
        audit_db,
    })
}

async fn record_reviews_policy_action_audit_result<T>(
    audit_db: Option<&Arc<AsyncDaemonDb>>,
    action_key: &'static str,
    title: &'static str,
    target: &ReviewTarget,
    payload_json: serde_json::Value,
    result: &Result<T, CliError>,
) {
    record_audit_result(
        audit_db,
        AuditEventDraft {
            source: "github",
            category: "githubMutation",
            kind: action_key,
            action_key,
            title: title.to_owned(),
            subject: Some(format!("{}#{}", target.repository, target.number)),
            actor: Some("Harness Monitor".to_owned()),
            payload_json: Some(payload_json),
            related_urls: vec![target.url.clone()],
        },
        result,
    )
    .await;
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
    use crate::{
        daemon::protocol::HarnessMonitorAuditEventsRequest,
        errors::CliErrorKind,
        reviews::{
            ReviewCheckStatus, ReviewMergeableState, ReviewPullRequestState, ReviewReviewStatus,
            ReviewTargetFlags,
        },
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

    #[tokio::test]
    async fn reviews_policy_action_audit_records_success_and_failure_events() {
        let dir = tempdir().expect("tempdir");
        let audit_db = Arc::new(
            AsyncDaemonDb::connect(&dir.path().join("harness.db"))
                .await
                .expect("open async daemon db"),
        );
        let target = sample_review_target();

        let success: Result<(), CliError> = Ok(());
        record_reviews_policy_action_audit_result(
            Some(&audit_db),
            "reviews.approve",
            "Approve pull request from policy workflow",
            &target,
            serde_json::json!({ "source": "policy_runtime" }),
            &success,
        )
        .await;

        let failure: Result<(), CliError> =
            Err(CliErrorKind::workflow_parse("merge blocked").into());
        record_reviews_policy_action_audit_result(
            Some(&audit_db),
            "reviews.merge",
            "Merge pull request from policy workflow",
            &target,
            serde_json::json!({ "source": "policy_runtime" }),
            &failure,
        )
        .await;

        let response = audit_db
            .load_audit_events(&HarnessMonitorAuditEventsRequest {
                limit: Some(10),
                sources: vec!["github".to_owned()],
                categories: vec!["githubMutation".to_owned()],
                subject: Some("Kong/mink-vcp-manager#1272".to_owned()),
                ..Default::default()
            })
            .await
            .expect("load policy action audit events");

        let approve = response
            .events
            .iter()
            .find(|event| event.action_key.as_deref() == Some("reviews.approve"))
            .expect("approve audit event");
        assert_eq!(approve.outcome, "success");
        assert_eq!(approve.severity, "info");
        assert_eq!(approve.related_urls, vec![target.url.clone()]);

        let merge = response
            .events
            .iter()
            .find(|event| event.action_key.as_deref() == Some("reviews.merge"))
            .expect("merge audit event");
        assert_eq!(merge.outcome, "failure");
        assert_eq!(merge.severity, "error");
        let payload = merge.payload_json.as_ref().expect("failure payload");
        assert!(
            payload["error"]
                .as_str()
                .is_some_and(|error| error.contains("merge blocked"))
        );
    }

    fn sample_review_target() -> ReviewTarget {
        ReviewTarget {
            pull_request_id: "pr_1272".to_owned(),
            repository_id: "repo_1".to_owned(),
            repository: "Kong/mink-vcp-manager".to_owned(),
            number: 1272,
            url: "https://github.com/Kong/mink-vcp-manager/pull/1272".to_owned(),
            state: ReviewPullRequestState::Open,
            head_sha: "abc123".to_owned(),
            mergeable: ReviewMergeableState::Mergeable,
            review_status: ReviewReviewStatus::ReviewRequired,
            check_status: ReviewCheckStatus::Success,
            flags: ReviewTargetFlags {
                is_draft: false,
                policy_blocked: false,
                viewer_can_update: true,
            },
            viewer_can_merge_as_admin: false,
            required_failed_check_names: Vec::new(),
            check_suite_ids: vec!["check-suite-1".to_owned()],
        }
    }
}
