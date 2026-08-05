use async_trait::async_trait;
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_task_board::{
    TaskBoardDependencyCompletionRecord, TaskBoardDependencyCompletionSink,
    TaskBoardDependencyCompletionStatus, TaskBoardStatus, TaskBoardWorkflowStatus,
};

use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;

const COMPLETION_START: &str = "<!-- harness:dependency-completion:start -->";
const COMPLETION_HEADER: &str =
    "<!-- harness:dependency-completion:start -->\n## Dependency completion\n";
const COMPLETION_CLOSE: &str = "\n```\n<!-- harness:dependency-completion:end -->";

#[async_trait]
impl TaskBoardDependencyCompletionSink for AsyncDaemonDbHandle {
    async fn record(&self, record: &TaskBoardDependencyCompletionRecord) -> Result<(), CliError> {
        validate_record(record)?;
        let record = record.clone();
        let item_id = record.board_item_id.clone();
        self.0
            .update_task_board_item(&item_id, move |item| {
                if item.workflow.execution_id.as_deref()
                    != Some(record.workflow_execution_id.as_str())
                {
                    return Err(CliErrorKind::workflow_parse(
                        "dependency completion does not match the ticket workflow execution",
                    )
                    .into());
                }
                if let Some(existing) = completion_from_body(&item.body)? {
                    if existing == record {
                        return Ok(false);
                    }
                    validate_record_advance(&existing, &record)?;
                }
                if matches!(
                    item.workflow.status,
                    TaskBoardWorkflowStatus::Completed
                        | TaskBoardWorkflowStatus::Failed
                        | TaskBoardWorkflowStatus::Cancelled
                ) {
                    return Err(CliErrorKind::workflow_io(
                        "dependency completion cannot advance a terminal ticket workflow",
                    )
                    .into());
                }
                item.body = render_completion_body(&item.body, &record)?;
                item.workflow.last_error = None;
                apply_record_status(item, &record);
                Ok(true)
            })
            .await?;
        Ok(())
    }
}

fn apply_record_status(
    item: &mut harness_task_board::TaskBoardItem,
    record: &TaskBoardDependencyCompletionRecord,
) {
    match record.status {
        TaskBoardDependencyCompletionStatus::ApprovalSubmitted => {
            item.status = TaskBoardStatus::InProgress;
            item.workflow.status = TaskBoardWorkflowStatus::Running;
            item.workflow.current_step_id = Some("dependency_approval_submitted".into());
        }
        TaskBoardDependencyCompletionStatus::HumanRequired => {
            item.status = TaskBoardStatus::HumanRequired;
            item.workflow.status = TaskBoardWorkflowStatus::Paused;
            item.workflow.current_step_id = Some("dependency_approval_human_required".into());
            item.workflow.last_error = Some(record.detail.clone());
        }
        TaskBoardDependencyCompletionStatus::ReverificationRequired => {
            item.status = TaskBoardStatus::InProgress;
            item.workflow.status = TaskBoardWorkflowStatus::Running;
            item.workflow.current_step_id = Some("dependency_reverification_required".into());
        }
        TaskBoardDependencyCompletionStatus::WaitingForGates => {
            item.status = TaskBoardStatus::InProgress;
            item.workflow.status = TaskBoardWorkflowStatus::Running;
            item.workflow.current_step_id = Some("dependency_waiting_for_merge_gates".into());
        }
        TaskBoardDependencyCompletionStatus::Merged => {
            item.status = TaskBoardStatus::Done;
            item.workflow.status = TaskBoardWorkflowStatus::Completed;
            item.workflow.current_step_id = Some("dependency_merged".into());
        }
    }
}

fn render_completion_body(
    body: &str,
    record: &TaskBoardDependencyCompletionRecord,
) -> Result<String, CliError> {
    let json = serde_json::to_string_pretty(record).map_err(|error| {
        CliErrorKind::workflow_parse(format!("encode dependency completion record: {error}"))
    })?;
    let detail = serde_json::to_string(&record.detail).map_err(|error| {
        CliErrorKind::workflow_parse(format!("encode dependency completion detail: {error}"))
    })?;
    let section = format!(
        "{COMPLETION_START}\n## Dependency completion\n\n- Verified head: `{}`\n- Approvals: {}/{}\n- Merge method: `{:?}`\n- Status: `{:?}`\n- Detail: {detail}\n\n```json\n{json}{COMPLETION_CLOSE}",
        record.verified_head_revision,
        record.current_approvals,
        record.required_approvals,
        record.merge_method,
        record.status,
    );
    Ok(replace_section(body, &section))
}

fn replace_section(body: &str, section: &str) -> String {
    let Some(start) = body.rfind(COMPLETION_HEADER) else {
        return append_section(body, section);
    };
    let suffix = &body[start..];
    let Some(end_offset) = suffix.find(COMPLETION_CLOSE) else {
        return append_section(body, section);
    };
    let end = start + end_offset + COMPLETION_CLOSE.len();
    format!("{}{}{}", &body[..start], section, &body[end..])
}

fn append_section(body: &str, section: &str) -> String {
    let separator = if body.trim().is_empty() { "" } else { "\n\n" };
    format!("{}{separator}{section}", body.trim_end())
}

fn completion_from_body(
    body: &str,
) -> Result<Option<TaskBoardDependencyCompletionRecord>, CliError> {
    let Some(start) = body.rfind(COMPLETION_HEADER) else {
        return Ok(None);
    };
    let suffix = &body[start + COMPLETION_START.len()..];
    let Some(json_start) = suffix.find("```json\n") else {
        return Ok(None);
    };
    let json_start = json_start + "```json\n".len();
    let Some(json_end) = suffix[json_start..].find(COMPLETION_CLOSE) else {
        return Ok(None);
    };
    let json_end = json_end + json_start;
    serde_json::from_str(&suffix[json_start..json_end])
        .map(Some)
        .map_err(|error| {
            CliErrorKind::workflow_parse(format!(
                "decode dependency completion ticket evidence: {error}"
            ))
            .into()
        })
}

fn validate_record(record: &TaskBoardDependencyCompletionRecord) -> Result<(), CliError> {
    if record.schema_version != harness_task_board::TASK_BOARD_DEPENDENCY_COMPLETION_SCHEMA_VERSION
        || [
            record.route_id.as_str(),
            record.board_item_id.as_str(),
            record.workflow_execution_id.as_str(),
            record.repository.as_str(),
            record.verified_head_revision.as_str(),
            record.detail.as_str(),
        ]
        .iter()
        .any(|value| value.trim().is_empty() || value.trim() != *value)
        || record.pull_request_number == 0
        || record.current_approvals > record.required_approvals
            && record.status == TaskBoardDependencyCompletionStatus::HumanRequired
    {
        return Err(
            CliErrorKind::workflow_parse("dependency completion ticket record is invalid").into(),
        );
    }
    Ok(())
}

fn validate_record_advance(
    existing: &TaskBoardDependencyCompletionRecord,
    next: &TaskBoardDependencyCompletionRecord,
) -> Result<(), CliError> {
    let same_scope = existing.route_id == next.route_id
        && existing.board_item_id == next.board_item_id
        && existing.workflow_execution_id == next.workflow_execution_id
        && existing.repository == next.repository
        && existing.pull_request_number == next.pull_request_number
        && existing.verified_head_revision == next.verified_head_revision
        && existing.merge_method == next.merge_method;
    if !same_scope || existing.status == TaskBoardDependencyCompletionStatus::Merged {
        return Err(CliErrorKind::workflow_parse(
            "dependency completion conflicts with its retained ticket history",
        )
        .into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::daemon::db::AsyncDaemonDb;
    use crate::daemon::db_open::AsyncDaemonDbConnect;
    use harness_task_board::TaskBoardItem;
    use harness_task_board::github::GitHubMergeMethod;

    #[test]
    fn ticket_section_round_trips_and_replaces_without_duplication() {
        let first = record(TaskBoardDependencyCompletionStatus::ApprovalSubmitted);
        let body = render_completion_body("Original", &first).expect("render");
        assert_eq!(completion_from_body(&body).expect("parse"), Some(first));

        let merged = record(TaskBoardDependencyCompletionStatus::Merged);
        let body = render_completion_body(&body, &merged).expect("replace");
        assert_eq!(body.matches(COMPLETION_START).count(), 1);
        assert_eq!(completion_from_body(&body).expect("parse"), Some(merged));
    }

    #[test]
    fn malformed_user_marker_does_not_block_a_new_completion_section() {
        let body = render_completion_body(
            "User context\n\n<!-- harness:dependency-completion:start -->\n## Dependency completion\n",
            &record(TaskBoardDependencyCompletionStatus::ApprovalSubmitted),
        )
        .expect("render");

        assert_eq!(
            completion_from_body(&body)
                .expect("parse")
                .expect("completion")
                .status,
            TaskBoardDependencyCompletionStatus::ApprovalSubmitted
        );
        assert!(body.ends_with("<!-- harness:dependency-completion:end -->"));
    }

    #[tokio::test]
    async fn database_sink_advances_the_bound_ticket_and_is_idempotent() {
        let directory = tempfile::tempdir().expect("tempdir");
        let database = AsyncDaemonDb::connect(&directory.path().join("harness.db"))
            .await
            .expect("open db");
        let database = AsyncDaemonDbHandle(database);
        let mut item = TaskBoardItem::new(
            "item-1".into(),
            "Dependency update".into(),
            "Original ticket context".into(),
            "2026-07-30T10:00:00Z".into(),
        );
        item.status = TaskBoardStatus::InProgress;
        item.workflow.execution_id = Some("execution-1".into());
        item.workflow.status = TaskBoardWorkflowStatus::Running;
        database
            .create_task_board_item(item)
            .await
            .expect("create ticket");

        let approval = record(TaskBoardDependencyCompletionStatus::ApprovalSubmitted);
        TaskBoardDependencyCompletionSink::record(&database.clone(), &approval)
            .await
            .expect("record approval");
        TaskBoardDependencyCompletionSink::record(&database.clone(), &approval)
            .await
            .expect("idempotent approval replay");
        let merged = record(TaskBoardDependencyCompletionStatus::Merged);
        TaskBoardDependencyCompletionSink::record(&database.clone(), &merged)
            .await
            .expect("record merge");

        let item = database
            .task_board_item("item-1")
            .await
            .expect("load ticket");
        assert_eq!(item.status, TaskBoardStatus::Done);
        assert_eq!(item.workflow.status, TaskBoardWorkflowStatus::Completed);
        assert_eq!(
            item.workflow.current_step_id.as_deref(),
            Some("dependency_merged")
        );
        assert_eq!(item.body.matches(COMPLETION_START).count(), 1);
        assert!(item.body.contains("\"status\": \"merged\""));
    }

    #[tokio::test]
    async fn database_sink_does_not_resurrect_a_cancelled_workflow() {
        let directory = tempfile::tempdir().expect("tempdir");
        let database = AsyncDaemonDb::connect(&directory.path().join("harness.db"))
            .await
            .expect("open db");
        let database = AsyncDaemonDbHandle(database);
        let mut item = TaskBoardItem::new(
            "item-1".into(),
            "Dependency update".into(),
            "Original ticket context".into(),
            "2026-07-30T10:00:00Z".into(),
        );
        item.workflow.execution_id = Some("execution-1".into());
        item.workflow.status = TaskBoardWorkflowStatus::Cancelled;
        database
            .create_task_board_item(item)
            .await
            .expect("create ticket");

        let error = TaskBoardDependencyCompletionSink::record(
            &database.clone(),
            &record(TaskBoardDependencyCompletionStatus::Merged),
        )
        .await
        .expect_err("terminal workflow must reject completion");
        assert!(error.to_string().contains("terminal ticket workflow"));
        let item = database
            .task_board_item("item-1")
            .await
            .expect("load ticket");
        assert_eq!(item.workflow.status, TaskBoardWorkflowStatus::Cancelled);
        assert!(!item.body.contains(COMPLETION_HEADER));
    }

    fn record(status: TaskBoardDependencyCompletionStatus) -> TaskBoardDependencyCompletionRecord {
        TaskBoardDependencyCompletionRecord {
            schema_version: harness_task_board::TASK_BOARD_DEPENDENCY_COMPLETION_SCHEMA_VERSION,
            route_id: "route-1".into(),
            board_item_id: "item-1".into(),
            workflow_execution_id: "execution-1".into(),
            repository: "acme/widgets".into(),
            pull_request_number: 17,
            verified_head_revision: "0123456789abcdef".into(),
            merge_method: GitHubMergeMethod::Squash,
            status,
            current_approvals: 1,
            required_approvals: 1,
            detail: "recorded".into(),
        }
    }
}
