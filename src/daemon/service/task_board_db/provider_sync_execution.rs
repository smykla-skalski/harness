use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{TaskBoardSyncRequest, TaskBoardSyncResponse};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::{
    ExternalSyncBatch, TaskBoardExternalCreateStore, assign_external_create_recovery,
    blocked_external_create_follow_ups, blocked_external_create_recovery,
    load_external_create_recovery_work, prepare_external_create_recovery,
    sync_external_tasks_scoped_with_recovery,
};
use crate::task_board::{
    ExternalProvider, ExternalSyncClient, ExternalSyncConfig, ExternalSyncDirection,
    ExternalSyncOptions, configured_sync_clients_without_review_requests,
};

use super::TaskBoardSyncRunContext;
use super::provider_sync_context_store::ProviderSyncRunStore;
use super::sync_audit::{SyncExecutionMetrics, TaskBoardSyncAuditTrigger};

pub(super) async fn execute(
    db: &AsyncDaemonDb,
    request: &TaskBoardSyncRequest,
    context: &TaskBoardSyncRunContext,
    metrics: &mut SyncExecutionMetrics,
) -> Result<TaskBoardSyncResponse, CliError> {
    let options = super::super::task_board::sync_options(request);
    let follow_ups = db
        .list_pending_external_create_follow_ups(request.provider)
        .await?;
    if options.dry_run && !follow_ups.is_empty() {
        let error =
            CliErrorKind::workflow_io("pending provider create follow-up blocks dry-run sync")
                .into();
        return finish_blocked(
            metrics,
            blocked_external_create_follow_ups(follow_ups, error),
        );
    }
    if !options.dry_run
        && let Err(error) =
            super::sync_audit::record_external_create_follow_ups(db, &follow_ups).await
    {
        return finish_blocked(
            metrics,
            blocked_external_create_follow_ups(follow_ups, error),
        );
    }
    let work = load_external_create_recovery_work(db, request.provider).await?;
    let mut prepared = match prepare_external_create_recovery(db, options, work).await {
        Ok(prepared) => prepared,
        Err(batch) => return finish_blocked(metrics, batch),
    };
    if !options.dry_run
        && let Err(error) =
            super::sync_audit::record_external_create_follow_ups(db, prepared.follow_ups()).await
    {
        return finish_blocked(metrics, blocked_external_create_recovery(prepared, error));
    }
    prepared.clear_follow_ups();
    let config = match super::active_external_sync_config_db(db).await {
        Ok(config) => config,
        Err(error) if prepared.is_empty() => return Err(error),
        Err(error) => {
            return finish_blocked(metrics, blocked_external_create_recovery(prepared, error));
        }
    };
    // A user-pressed Sync must reflect edits made directly on GitHub (a new
    // assignee, a review request); those never bump the read generation, so cached
    // searches up to an hour old would hide them. Advance it once so every GitHub
    // read this sync makes hits the API. Background reconciles skip this Requested
    // branch and keep their cache; only the reconcile right after a manual Sync
    // refetches once.
    if requested_github_read(context, &options, &config) {
        crate::github_api::refresh_read_generation().await;
    }
    let mut clients =
        match configured_sync_clients_without_review_requests(&config, request.provider) {
            Ok(clients) => clients,
            Err(error) if prepared.is_empty() => return Err(error),
            Err(error) => {
                return finish_blocked(metrics, blocked_external_create_recovery(prepared, error));
            }
        };
    let plan = match assign_external_create_recovery(prepared, &clients) {
        Ok(plan) => plan,
        Err(batch) => return finish_blocked(metrics, batch),
    };
    let has_recovery = plan.has_recovery();
    let shared_clients = match super::shared_review_request_clients(db, request).await {
        Ok(clients) => clients,
        Err(error) if plan.is_empty() => return Err(error),
        Err(error) => return finish_blocked(metrics, plan.into_blocked(error)),
    };
    clients.extend(
        shared_clients
            .into_iter()
            .map(|client| Box::new(client) as Box<dyn ExternalSyncClient>),
    );
    super::super::task_board::log_sync_request(request, &config, clients.len());
    if !has_recovery {
        super::super::task_board::ensure_sync_request_can_run(request, &config, &clients)?;
    }
    let run_store = ProviderSyncRunStore::new(db, context.coordinator_fence());
    let mut batch =
        sync_external_tasks_scoped_with_recovery(&run_store, options, &clients, plan).await?;
    if !options.dry_run
        && let Err(error) = super::sync_audit::record_external_create_follow_ups(
            db,
            &batch.external_create_follow_ups,
        )
        .await
    {
        batch.terminal_error = Some(combine_follow_up_error(batch.terminal_error.take(), error));
    }
    metrics.capture(&batch);
    let batch = batch.into_completed()?;
    let items = db.list_task_board_items(request.status).await?;
    let summary =
        super::super::task_board::build_sync_response_from_items(&items, &config, batch.operations);
    super::super::task_board::log_sync_completion(&summary);
    Ok(summary)
}

fn requested_github_read(
    context: &TaskBoardSyncRunContext,
    options: &ExternalSyncOptions,
    config: &ExternalSyncConfig,
) -> bool {
    context.trigger() == TaskBoardSyncAuditTrigger::Requested
        && matches!(options.provider, None | Some(ExternalProvider::GitHub))
        && matches!(
            options.direction,
            ExternalSyncDirection::Pull | ExternalSyncDirection::Both
        )
        && config.token_for(ExternalProvider::GitHub).is_some()
}

fn combine_follow_up_error(existing: Option<CliError>, follow_up: CliError) -> CliError {
    let Some(existing) = existing else {
        return follow_up;
    };
    crate::errors::CliErrorKind::workflow_io(format!(
        "task-board provider sync failed: {existing}; \
external create follow-up persistence failed: {follow_up}"
    ))
    .into()
}

fn finish_blocked(
    metrics: &mut SyncExecutionMetrics,
    batch: ExternalSyncBatch,
) -> Result<TaskBoardSyncResponse, CliError> {
    metrics.capture(&batch);
    match batch.into_completed() {
        Ok(_) => unreachable!("blocked provider create recovery must remain terminal"),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use sqlx::query;
    use tempfile::tempdir;

    use super::*;
    use crate::daemon::protocol::HarnessMonitorAuditEventsRequest;
    use crate::task_board::{
        ExternalCreateOutcome, ExternalProvider, ExternalRefSyncState, ExternalSyncConfig,
        ExternalSyncDirection, ExternalSyncOptions, ExternalTaskRef, TaskBoardExternalCreateBegin,
        TaskBoardItem, TaskBoardStatus,
    };

    #[test]
    fn requested_github_read_gates_the_read_refresh() {
        let github = ExternalSyncConfig::default().with_github_token_override(Some("token"));
        let pull = ExternalSyncOptions {
            direction: ExternalSyncDirection::Pull,
            ..ExternalSyncOptions::default()
        };
        let requested = TaskBoardSyncRunContext::requested();

        assert!(
            requested_github_read(&requested, &pull, &github),
            "a requested GitHub pull with a token must refresh"
        );
        assert!(
            !requested_github_read(
                &TaskBoardSyncRunContext::orchestrator(None, None, None),
                &pull,
                &github,
            ),
            "orchestrator syncs keep their cache"
        );
        assert!(
            !requested_github_read(
                &requested,
                &ExternalSyncOptions {
                    provider: Some(ExternalProvider::Todoist),
                    direction: ExternalSyncDirection::Pull,
                    ..ExternalSyncOptions::default()
                },
                &github,
            ),
            "a Todoist-only pull must not refresh GitHub even with a token set"
        );
        assert!(
            !requested_github_read(
                &requested,
                &ExternalSyncOptions {
                    direction: ExternalSyncDirection::Push,
                    ..ExternalSyncOptions::default()
                },
                &github,
            ),
            "push syncs perform no reads"
        );
        assert!(
            !requested_github_read(&requested, &pull, &ExternalSyncConfig::default()),
            "no GitHub token means nothing to read"
        );
    }

    #[tokio::test]
    async fn config_failure_reports_create_once_and_acks_the_follow_up() {
        let (_dir, db, request) = config_failure_fixture().await;
        let mut metrics = SyncExecutionMetrics::default();

        execute(
            &db,
            &request,
            &TaskBoardSyncRunContext::requested(),
            &mut metrics,
        )
        .await
        .expect_err("configuration load must fail");

        assert_eq!(metrics.operations().len(), 1);
        assert!(metrics.operations()[0].applied);
        assert_eq!(
            metrics.operations()[0].external_id.as_deref(),
            Some("remote-config-recovery")
        );
        assert!(
            db.task_board_external_create_receipt(
                "task-config-recovery",
                ExternalProvider::Todoist,
            )
            .await
            .expect("create receipt")
            .is_some()
        );
        assert!(
            db.list_pending_task_board_external_create_follow_ups(Some(ExternalProvider::Todoist))
                .await
                .expect("pending follow-ups")
                .is_empty()
        );
        let events = follow_up_events(&db).await;
        assert_eq!(events.len(), 1);
        let payload = events[0].payload_json.as_ref().expect("follow-up payload");
        assert_eq!(payload["operation_count"].as_u64(), Some(0));
        assert_eq!(payload["applied_operation_count"].as_u64(), Some(0));

        let mut second_metrics = SyncExecutionMetrics::default();
        execute(
            &db,
            &request,
            &TaskBoardSyncRunContext::requested(),
            &mut second_metrics,
        )
        .await
        .expect_err("configuration remains invalid");

        assert!(second_metrics.operations().is_empty());
        assert_eq!(follow_up_events(&db).await.len(), 1);
    }

    #[tokio::test]
    async fn pending_attached_follow_up_never_reemits_an_applied_sync_operation() {
        let (_dir, db, request) = config_failure_fixture().await;
        let created = db
            .list_created_task_board_external_create_intents()
            .await
            .expect("created intents")
            .into_iter()
            .next()
            .expect("created intent");
        db.finalize_task_board_external_create_intent(&created)
            .await
            .expect("finalize before simulated crash");
        let mut first_metrics = SyncExecutionMetrics::default();

        execute(
            &db,
            &request,
            &TaskBoardSyncRunContext::requested(),
            &mut first_metrics,
        )
        .await
        .expect_err("configuration remains invalid");

        assert!(first_metrics.operations().is_empty());
        assert_eq!(follow_up_events(&db).await.len(), 1);
        let mut second_metrics = SyncExecutionMetrics::default();
        execute(
            &db,
            &request,
            &TaskBoardSyncRunContext::requested(),
            &mut second_metrics,
        )
        .await
        .expect_err("configuration remains invalid");
        assert!(second_metrics.operations().is_empty());
        assert_eq!(follow_up_events(&db).await.len(), 1);
    }

    #[tokio::test]
    async fn dry_run_leaves_pending_attached_follow_up_untouched() {
        let (_dir, db, mut request) = config_failure_fixture().await;
        let created = db
            .list_created_task_board_external_create_intents()
            .await
            .expect("created intents")
            .into_iter()
            .next()
            .expect("created intent");
        db.finalize_task_board_external_create_intent(&created)
            .await
            .expect("finalize before preview");
        request.dry_run = true;
        let mut metrics = SyncExecutionMetrics::default();

        let error = execute(
            &db,
            &request,
            &TaskBoardSyncRunContext::requested(),
            &mut metrics,
        )
        .await
        .expect_err("pending follow-up must block preview");

        assert!(error.message().contains("blocks dry-run"));
        assert!(metrics.operations().is_empty());
        assert!(follow_up_events(&db).await.is_empty());
        assert_eq!(
            db.list_pending_task_board_external_create_follow_ups(Some(ExternalProvider::Todoist))
                .await
                .expect("pending follow-ups")
                .len(),
            1
        );
    }

    async fn config_failure_fixture() -> (tempfile::TempDir, AsyncDaemonDb, TaskBoardSyncRequest) {
        let dir = tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
            .await
            .expect("database");
        let mut item = TaskBoardItem::new(
            "task-config-recovery".into(),
            "Create title".into(),
            "Create body".into(),
            "2026-07-16T10:00:00Z".into(),
        );
        item.project_id = Some("provider-project".into());
        db.create_task_board_item(item).await.expect("create item");
        let started = db
            .begin_task_board_external_create_intent(
                "task-config-recovery",
                ExternalProvider::Todoist,
                "todoist:scope",
                "provider-project",
            )
            .await
            .expect("begin create");
        let TaskBoardExternalCreateBegin::Started(intent) = started else {
            panic!("expected started create intent");
        };
        let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-config-recovery");
        let outcome = ExternalCreateOutcome {
            reference: reference.clone(),
            provider_revision: None,
            provider_project_id: Some("provider-project".into()),
        };
        let mut baseline = reference.into_core_ref();
        baseline.sync_state = Some(ExternalRefSyncState {
            title: Some("Create title".into()),
            body: Some("Create body".into()),
            status: Some(TaskBoardStatus::Backlog),
            project_id: Some("provider-project".into()),
            updated_at: None,
            synced_at: Some("2026-07-16T10:00:00Z".into()),
        });
        db.record_task_board_external_create_outcome(&intent, &outcome, &baseline)
            .await
            .expect("record create");
        query(
            "UPDATE task_board_orchestrator_settings
             SET settings_json = '{' WHERE singleton = 1",
        )
        .execute(db.pool())
        .await
        .expect("corrupt settings");
        let request = TaskBoardSyncRequest {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Pull,
            dry_run: false,
            ..TaskBoardSyncRequest::default()
        };
        (dir, db, request)
    }

    async fn follow_up_events(
        db: &AsyncDaemonDb,
    ) -> Vec<crate::daemon::protocol::HarnessMonitorAuditEvent> {
        db.load_audit_events(&HarnessMonitorAuditEventsRequest {
            action_keys: vec!["task_board.external_create_follow_up".into()],
            ..HarnessMonitorAuditEventsRequest::default()
        })
        .await
        .expect("load follow-up events")
        .events
    }
}
