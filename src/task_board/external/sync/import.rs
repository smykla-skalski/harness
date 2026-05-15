use crate::task_board::types::{PlanningState, TaskBoardStatus};

use crate::task_board::external::{ExternalProvider, ExternalTask, ExternalTaskRef};

pub(super) fn external_item_id(reference: &ExternalTaskRef) -> String {
    format!(
        "{}-{}",
        reference.provider,
        safe_id_part(&reference.external_id)
    )
}

pub(super) fn imported_external_planning(task: &ExternalTask) -> Option<PlanningState> {
    match task.reference.provider {
        ExternalProvider::GitHub if task.status != TaskBoardStatus::NeedsYou => {
            Some(PlanningState {
                summary: Some(github_import_summary(task)),
                approved_by: None,
                approved_at: None,
            })
        }
        ExternalProvider::GitHub | ExternalProvider::Todoist => None,
    }
}

fn github_import_summary(task: &ExternalTask) -> String {
    let title = task.title.trim();
    match (title.is_empty(), task.reference.url.as_deref()) {
        (false, Some(url)) => {
            format!("Handle the linked GitHub issue \"{title}\" and preserve scope from {url}.")
        }
        (false, None) => {
            format!(
                "Handle the linked GitHub issue \"{title}\" and preserve scope from the issue body."
            )
        }
        (true, Some(url)) => {
            format!("Handle the linked GitHub issue and preserve scope from {url}.")
        }
        (true, None) => {
            "Handle the linked GitHub issue and preserve scope from the issue body.".to_string()
        }
    }
}

fn safe_id_part(value: &str) -> String {
    let mut sanitized = String::with_capacity(value.len());
    for character in value.chars() {
        if character.is_ascii_alphanumeric() || character == '-' || character == '_' {
            sanitized.push(character);
        } else {
            sanitized.push('-');
        }
    }
    sanitized.trim_matches('-').to_string()
}
