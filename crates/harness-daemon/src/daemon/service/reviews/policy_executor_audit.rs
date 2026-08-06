use std::sync::Arc;

use crate::daemon::audit_events::{AuditEventDraft, record_audit_result};
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::reviews::ReviewTarget;
use harness_kernel::errors::CliError;

pub(super) async fn record_reviews_policy_action_audit_result<T>(
    audit_db: Option<&Arc<AsyncDaemonDbHandle>>,
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
