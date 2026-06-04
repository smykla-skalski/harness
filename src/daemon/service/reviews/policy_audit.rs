use std::sync::Arc;

use serde_json::json;

use crate::daemon::audit_events::{AuditEventRecordDraft, record_audit_event};
use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;
use crate::reviews::{
    ReviewsPolicyRunResponse, ReviewsPolicyRunStartRequest, ReviewsPolicyRunStatus,
};
use crate::task_board::policy_runtime::models::PolicyRunTrigger;

pub(crate) async fn record_policy_run_start_result(
    audit_db: Option<&Arc<AsyncDaemonDb>>,
    request: &ReviewsPolicyRunStartRequest,
    result: &Result<ReviewsPolicyRunResponse, CliError>,
) {
    let subject = policy_request_subject(request);
    match result {
        Ok(run) => {
            record_audit_event(
                audit_db,
                AuditEventRecordDraft {
                    source: "policy",
                    category: "policyWorkflow",
                    kind: "policy.workflow.start",
                    severity: "info",
                    outcome: "success",
                    title: "Start policy workflow run".to_owned(),
                    summary: format!(
                        "Started policy workflow '{}' for {subject}",
                        run.workflow_id
                    ),
                    subject: Some(subject),
                    actor: Some("Harness Monitor".to_owned()),
                    correlation_id: Some(run.run_id.clone()),
                    action_key: Some("policy.workflow.start".to_owned()),
                    payload_json: Some(policy_run_payload(run)),
                    legacy_message: None,
                    related_urls: vec![request.target.url.clone()],
                },
            )
            .await;
            record_policy_run_status_event(audit_db, run).await;
        }
        Err(error) => {
            record_audit_event(
                audit_db,
                AuditEventRecordDraft {
                    source: "policy",
                    category: "policyWorkflow",
                    kind: "policy.workflow.start",
                    severity: "error",
                    outcome: "failure",
                    title: "Start policy workflow run".to_owned(),
                    summary: format!("Failed to start policy workflow for {subject}: {error}"),
                    subject: Some(subject),
                    actor: Some("Harness Monitor".to_owned()),
                    correlation_id: None,
                    action_key: Some("policy.workflow.start".to_owned()),
                    payload_json: Some(json!({
                        "workflow_id": request.normalized_workflow_id(),
                        "target": policy_request_subject(request),
                        "trigger": request.trigger,
                        "method": request.method,
                        "error": error.to_string(),
                    })),
                    legacy_message: None,
                    related_urls: vec![request.target.url.clone()],
                },
            )
            .await;
        }
    }
}

pub(crate) async fn record_policy_run_resume_result(
    audit_db: Option<&Arc<AsyncDaemonDb>>,
    trigger: PolicyRunTrigger,
    run: &ReviewsPolicyRunResponse,
) {
    record_audit_event(
        audit_db,
        AuditEventRecordDraft {
            source: "policy",
            category: "policyWorkflow",
            kind: "policy.workflow.resume",
            severity: "info",
            outcome: "success",
            title: "Resume policy workflow run".to_owned(),
            summary: format!(
                "Resumed policy workflow '{}' for {}",
                run.workflow_id,
                policy_run_subject(run)
            ),
            subject: Some(policy_run_subject(run)),
            actor: Some("Harness Monitor".to_owned()),
            correlation_id: Some(run.run_id.clone()),
            action_key: Some("policy.workflow.resume".to_owned()),
            payload_json: Some(json!({
                "run_id": &run.run_id,
                "workflow_id": &run.workflow_id,
                "trigger": trigger,
                "status": run.status,
            })),
            legacy_message: None,
            related_urls: Vec::new(),
        },
    )
    .await;
    record_policy_run_status_event(audit_db, run).await;
}

async fn record_policy_run_status_event(
    audit_db: Option<&Arc<AsyncDaemonDb>>,
    run: &ReviewsPolicyRunResponse,
) {
    let descriptor = PolicyRunAuditDescriptor::from_status(run.status);
    record_audit_event(
        audit_db,
        AuditEventRecordDraft {
            source: "policy",
            category: "policyWorkflow",
            kind: descriptor.kind,
            severity: descriptor.severity,
            outcome: descriptor.outcome,
            title: descriptor.title.to_owned(),
            summary: descriptor.summary(run),
            subject: Some(policy_run_subject(run)),
            actor: Some("Harness Monitor".to_owned()),
            correlation_id: Some(run.run_id.clone()),
            action_key: Some(descriptor.kind.to_owned()),
            payload_json: Some(policy_run_payload(run)),
            legacy_message: None,
            related_urls: Vec::new(),
        },
    )
    .await;
}

struct PolicyRunAuditDescriptor {
    kind: &'static str,
    severity: &'static str,
    outcome: &'static str,
    title: &'static str,
}

impl PolicyRunAuditDescriptor {
    const fn from_status(status: ReviewsPolicyRunStatus) -> Self {
        match status {
            ReviewsPolicyRunStatus::Completed => Self {
                kind: "policy.workflow.complete",
                severity: "info",
                outcome: "success",
                title: "Complete policy workflow run",
            },
            ReviewsPolicyRunStatus::Failed => Self {
                kind: "policy.workflow.fail",
                severity: "error",
                outcome: "failure",
                title: "Fail policy workflow run",
            },
            ReviewsPolicyRunStatus::Waiting => Self {
                kind: "policy.workflow.wait",
                severity: "info",
                outcome: "waiting",
                title: "Wait policy workflow run",
            },
            ReviewsPolicyRunStatus::Cancelled => Self {
                kind: "policy.workflow.cancel",
                severity: "warning",
                outcome: "cancelled",
                title: "Cancel policy workflow run",
            },
            ReviewsPolicyRunStatus::Running => Self {
                kind: "policy.workflow.running",
                severity: "info",
                outcome: "running",
                title: "Run policy workflow",
            },
        }
    }

    #[expect(
        clippy::unused_self,
        reason = "descriptor methods keep the status-specific copy together"
    )]
    fn summary(&self, run: &ReviewsPolicyRunResponse) -> String {
        let subject = policy_run_subject(run);
        match run.status {
            ReviewsPolicyRunStatus::Completed => {
                format!(
                    "Policy workflow '{}' completed for {subject}",
                    run.workflow_id
                )
            }
            ReviewsPolicyRunStatus::Failed => format!(
                "Policy workflow '{}' failed for {subject}: {}",
                run.workflow_id,
                run.error_message.as_deref().unwrap_or("unknown error")
            ),
            ReviewsPolicyRunStatus::Waiting => {
                format!(
                    "Policy workflow '{}' is waiting for {subject}",
                    run.workflow_id
                )
            }
            ReviewsPolicyRunStatus::Cancelled => {
                format!(
                    "Policy workflow '{}' was cancelled for {subject}",
                    run.workflow_id
                )
            }
            ReviewsPolicyRunStatus::Running => {
                format!(
                    "Policy workflow '{}' is running for {subject}",
                    run.workflow_id
                )
            }
        }
    }
}

fn policy_request_subject(request: &ReviewsPolicyRunStartRequest) -> String {
    format!("{}#{}", request.target.repository, request.target.number)
}

fn policy_run_subject(run: &ReviewsPolicyRunResponse) -> String {
    format!(
        "{}#{}",
        run.subject.repository, run.subject.pull_request_number
    )
}

fn policy_run_payload(run: &ReviewsPolicyRunResponse) -> serde_json::Value {
    json!({
        "run_id": &run.run_id,
        "workflow_id": &run.workflow_id,
        "subject": policy_run_subject(run),
        "trigger": run.trigger,
        "status": run.status,
        "waiting_on": &run.waiting_on,
        "completed_at": &run.completed_at,
        "error_message": &run.error_message,
        "step_count": run.steps.len(),
        "action_keys": run.steps.iter().filter_map(|step| step.action_key.as_ref()).collect::<Vec<_>>(),
    })
}
