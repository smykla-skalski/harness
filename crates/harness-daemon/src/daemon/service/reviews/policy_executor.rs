use std::sync::Arc;

use async_trait::async_trait;
use serde_json::json;

use crate::daemon::audit_events::{AuditEventDraft, record_audit_result};
use crate::daemon::db::AsyncDaemonDb;
#[cfg(test)]
use crate::daemon::db::task_board::prelude::PolicyRuntimeQueries;
use crate::daemon::service::reviews::token::{github_token, missing_token_error};
use crate::reviews::policy::ReviewsPolicyActionExecutor;
use crate::reviews::{ReviewTarget, ReviewsGitHubClient};
use crate::task_board::github::{
    ActionGateRequirement, GitHubMergeMethod, GitHubPullRequestEvidenceSource, MergeLedgerOutcome,
    PullRequestAction, PullRequestActionKind, PullRequestIdentity, merge_with_ledger,
};
use harness_kernel::errors::CliError;
use harness_kernel::errors::CliErrorKind;

#[path = "policy_executor_providers.rs"]
mod providers;

pub(crate) use providers::build_database_policy_provider_registry;
#[cfg(test)]
pub(crate) use providers::build_policy_provider_registry;

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
        let result = self.durable_merge(target, method).await;
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

impl DaemonReviewsPolicyExecutor {
    /// Merge through the durable action ledger when a database is available, so a
    /// restarted policy run never issues a second merge for the same head. The
    /// ledger records the intent before GitHub sees it and reconciles an
    /// uncertain prior attempt against fresh evidence before any retry. Without a
    /// database the merge still runs, gated by the fresh recheck inside
    /// `policy_merge`, just without cross-restart deduplication.
    async fn durable_merge(
        &self,
        target: &ReviewTarget,
        method: GitHubMergeMethod,
    ) -> Result<(), CliError> {
        // A blank head can never be admitted (`policy_merge` refuses it), so route
        // straight there rather than record a ledger intent that would only ever
        // resolve as an uncertain, un-reconcilable entry for an invalid action.
        if target.head_sha.trim().is_empty() {
            return self.client.policy_merge(target, method).await;
        }
        let Some(store) = self.audit_db.clone() else {
            return self.client.policy_merge(target, method).await;
        };
        let source = GitHubPullRequestEvidenceSource::new(self.client.protected());
        let action = PullRequestAction {
            id: format!(
                "reviews.merge:{}#{}@{}",
                target.repository, target.number, target.head_sha
            ),
            kind: PullRequestActionKind::Merge,
            identity: PullRequestIdentity::from_slug(target.repository.clone(), target.number)
                .with_url(Some(target.url.clone())),
            head_revision: target.head_sha.clone(),
        };
        let outcome = merge_with_ledger(
            store.as_ref(),
            &source,
            action,
            ActionGateRequirement::for_merge(),
            || self.client.merge_verified(target, method),
        )
        .await?;
        match outcome {
            MergeLedgerOutcome::Merged | MergeLedgerOutcome::AlreadyApplied => Ok(()),
            MergeLedgerOutcome::Blocked(blocks) => Err(CliErrorKind::workflow_io(format!(
                "refused merge for {}#{}: {}",
                target.repository,
                target.number,
                blocks
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join("; ")
            ))
            .into()),
        }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::db::AsyncAuditQueries;
    use crate::daemon::reviews_store::PolicyGraphQueries;
    use crate::task_board::policy_graph::PolicyCanvasWorkspace;
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
    async fn legacy_registry_dispatches_handoff_to_the_handoff_provider() {
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
            .expect("dispatch handoff in legacy registry");
        assert_eq!(execution.action_key, HANDOFF_ACTION_KEY);
    }

    #[tokio::test]
    async fn legacy_registry_still_routes_reviews_actions_to_the_reviews_provider() {
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
    async fn legacy_registry_dispatches_all_four_domains() {
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
    async fn database_registry_persists_all_orchestration_side_effects() {
        let dir = tempdir().expect("tempdir");
        let database = Arc::new(
            AsyncDaemonDb::connect(&dir.path().join("harness.db"))
                .await
                .expect("open async daemon db"),
        );
        let registry = build_database_policy_provider_registry(NoopExecutor, Arc::clone(&database));
        let actions = [
            PolicyActionDescriptor {
                provider: HANDOFF_PROVIDER.to_owned(),
                action_key: HANDOFF_ACTION_KEY.to_owned(),
                payload: Some(serde_json::json!({ "handoff_key": "next-handler" })),
            },
            PolicyActionDescriptor {
                provider: NOTIFICATION_PROVIDER.to_owned(),
                action_key: NOTIFICATION_ACTION_KEY.to_owned(),
                payload: Some(serde_json::json!({ "channel": "ops", "message": "merged" })),
            },
            PolicyActionDescriptor {
                provider: TASK_CREATION_PROVIDER.to_owned(),
                action_key: TASK_CREATION_ACTION_KEY.to_owned(),
                payload: Some(serde_json::json!({ "title": "Follow up" })),
            },
        ];

        for action in &actions {
            registry
                .execute(action, &execution_context())
                .await
                .expect("persist database side effect");
        }

        assert_eq!(
            database
                .policy_handoff_records()
                .await
                .expect("load handoffs")
                .len(),
            1
        );
        assert_eq!(
            database
                .pending_policy_events()
                .await
                .expect("load events")
                .len(),
            1
        );
        assert_eq!(
            database
                .policy_notification_records()
                .await
                .expect("load notifications")
                .len(),
            1
        );
        assert_eq!(
            database
                .policy_task_creation_records()
                .await
                .expect("load task creations")
                .len(),
            1
        );
    }

    #[tokio::test]
    async fn database_registry_refuses_actions_when_app_kill_switch_is_engaged() {
        let dir = tempdir().expect("tempdir");
        let database = Arc::new(
            AsyncDaemonDb::connect(&dir.path().join("harness.db"))
                .await
                .expect("open async daemon db"),
        );
        let mut workspace = PolicyCanvasWorkspace::seeded();
        workspace.spawn_kill_switch = true;
        database
            .replace_policy_workspace(&workspace)
            .await
            .expect("engage app kill switch");
        let registry = build_database_policy_provider_registry(NoopExecutor, database);
        let action = PolicyActionDescriptor {
            provider: HANDOFF_PROVIDER.to_owned(),
            action_key: HANDOFF_ACTION_KEY.to_owned(),
            payload: Some(serde_json::json!({ "handoff_key": "next-handler" })),
        };

        let error = registry
            .execute(&action, &execution_context())
            .await
            .expect_err("kill switch must block policy action");

        assert!(error.to_string().contains("policy automation is disabled"));
    }

    #[tokio::test]
    async fn database_registry_refuses_actions_when_policy_automation_is_disabled() {
        let dir = tempdir().expect("tempdir");
        let database = Arc::new(
            AsyncDaemonDb::connect(&dir.path().join("harness.db"))
                .await
                .expect("open async daemon db"),
        );
        let mut workspace = PolicyCanvasWorkspace::seeded();
        workspace.global_policy_enforcement_enabled = false;
        database
            .replace_policy_workspace(&workspace)
            .await
            .expect("disable policy automation");
        let registry = build_database_policy_provider_registry(NoopExecutor, database);
        let action = PolicyActionDescriptor {
            provider: HANDOFF_PROVIDER.to_owned(),
            action_key: HANDOFF_ACTION_KEY.to_owned(),
            payload: Some(serde_json::json!({ "handoff_key": "next-handler" })),
        };

        let error = registry
            .execute(&action, &execution_context())
            .await
            .expect_err("disabled policy automation must block action");

        assert!(error.to_string().contains("policy automation is disabled"));
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
            has_conflict_markers: Some(false),
            viewer_has_active_approval: Some(false),
            auto_merge_enabled: Some(false),
            approval_requirement_satisfied_after_viewer_approval: Some(true),
        }
    }
}
