use sha2::{Digest, Sha256};

use crate::task_board::{
    ExternalRefSyncState, TaskBoardConflictState, TaskBoardItem, TaskBoardSyncConflict,
};

use super::merge::matching_ref;
use super::{ExternalSyncField, ExternalTask};

pub(super) fn build_sync_conflicts(
    item: &TaskBoardItem,
    task: &ExternalTask,
    fields: &[ExternalSyncField],
    item_revision: i64,
) -> Vec<TaskBoardSyncConflict> {
    let base = matching_ref(item, &task.reference, task.project_id.as_deref())
        .and_then(|reference| reference.sync_state.as_ref());
    fields
        .iter()
        .map(|field| {
            let field_name = field_name(*field);
            TaskBoardSyncConflict {
                conflict_id: conflict_id(item, task, field_name),
                item_id: item.id.clone(),
                provider: task.reference.provider.into(),
                external_ref: task.reference.external_id.clone(),
                field: field_name.into(),
                base_value: base_value(base, *field),
                local_value: local_value(item, *field),
                remote_value: remote_value(task, *field),
                item_revision,
                provider_revision: task.updated_at.clone(),
                state: TaskBoardConflictState::Open,
            }
        })
        .collect()
}

fn conflict_id(item: &TaskBoardItem, task: &ExternalTask, field: &str) -> String {
    let identity = format!(
        "{}:{}:{}:{field}",
        item.id, task.reference.provider, task.reference.external_id
    );
    let digest = Sha256::digest(identity.as_bytes());
    format!("sync-conflict-{}", hex::encode(&digest[..16]))
}

const fn field_name(field: ExternalSyncField) -> &'static str {
    match field {
        ExternalSyncField::Title => "title",
        ExternalSyncField::Body => "body",
        ExternalSyncField::Status => "status",
        ExternalSyncField::Project => "project",
        ExternalSyncField::Url => "url",
    }
}

fn base_value(state: Option<&ExternalRefSyncState>, field: ExternalSyncField) -> serde_json::Value {
    let Some(state) = state else {
        return serde_json::Value::Null;
    };
    match field {
        ExternalSyncField::Title => serde_json::json!(state.title),
        ExternalSyncField::Body => serde_json::json!(state.body),
        ExternalSyncField::Status => serde_json::json!(state.status),
        ExternalSyncField::Project => serde_json::json!(state.project_id),
        ExternalSyncField::Url => serde_json::Value::Null,
    }
}

fn local_value(item: &TaskBoardItem, field: ExternalSyncField) -> serde_json::Value {
    match field {
        ExternalSyncField::Title => serde_json::json!(item.title),
        ExternalSyncField::Body => serde_json::json!(item.body),
        ExternalSyncField::Status => serde_json::json!(item.status),
        ExternalSyncField::Project => serde_json::json!(item.project_id),
        ExternalSyncField::Url => serde_json::Value::Null,
    }
}

fn remote_value(task: &ExternalTask, field: ExternalSyncField) -> serde_json::Value {
    match field {
        ExternalSyncField::Title => serde_json::json!(task.title),
        ExternalSyncField::Body => serde_json::json!(task.body),
        ExternalSyncField::Status => serde_json::json!(task.status),
        ExternalSyncField::Project => serde_json::json!(task.project_id),
        ExternalSyncField::Url => serde_json::json!(task.reference.url),
    }
}

#[cfg(test)]
mod tests {
    use crate::task_board::{
        ExternalProvider, ExternalRefSyncState, ExternalTaskRef, TaskBoardStatus,
    };

    use super::*;

    #[test]
    fn conflict_captures_three_way_title_values() {
        let mut item = TaskBoardItem::new(
            "task-1".into(),
            "Local title".into(),
            String::new(),
            "2026-07-15T10:00:00Z".into(),
        );
        item.status = TaskBoardStatus::InProgress;
        let mut reference =
            ExternalTaskRef::new(ExternalProvider::GitHub, "acme/widgets#17").into_core_ref();
        reference.sync_state = Some(ExternalRefSyncState {
            title: Some("Base title".into()),
            body: Some(String::new()),
            status: Some(TaskBoardStatus::Backlog),
            project_id: Some("acme/widgets".into()),
            updated_at: Some("2026-07-15T10:00:00Z".into()),
            synced_at: Some("2026-07-15T10:00:00Z".into()),
        });
        item.external_refs = vec![reference];
        let task = ExternalTask {
            reference: ExternalTaskRef::new(ExternalProvider::GitHub, "acme/widgets#17"),
            title: "Remote title".into(),
            body: String::new(),
            status: TaskBoardStatus::Done,
            project_id: Some("acme/widgets".into()),
            updated_at: Some("2026-07-15T10:05:00Z".into()),
            ..ExternalTask::default()
        };

        let conflicts = build_sync_conflicts(&item, &task, &[ExternalSyncField::Title], 7);

        assert_eq!(conflicts.len(), 1);
        assert_eq!(conflicts[0].base_value, serde_json::json!("Base title"));
        assert_eq!(conflicts[0].local_value, serde_json::json!("Local title"));
        assert_eq!(conflicts[0].remote_value, serde_json::json!("Remote title"));
        assert_eq!(conflicts[0].item_revision, 7);
    }
}
