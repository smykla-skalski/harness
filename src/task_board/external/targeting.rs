use crate::task_board::{TaskBoardItem, normalize_repository_slug};

use super::{ExternalProvider, ExternalTask};

pub(super) fn execution_repository_for_task(task: &ExternalTask) -> Option<String> {
    (task.reference.provider == ExternalProvider::GitHub)
        .then(|| normalize_repository_slug(task.project_id.as_deref()))
        .flatten()
}

pub(super) fn github_repository_for_item(item: &TaskBoardItem) -> Option<&str> {
    item.execution_repository
        .as_deref()
        .or(item.project_id.as_deref())
}

#[cfg(test)]
mod tests {
    use crate::task_board::{ExternalTaskRef, TaskBoardStatus};

    use super::*;

    #[test]
    fn github_task_repository_is_normalized_without_changing_project_identity() {
        let task = external_task(ExternalProvider::GitHub, Some(" Acme/Widgets "));

        assert_eq!(
            execution_repository_for_task(&task).as_deref(),
            Some("acme/widgets")
        );
        assert_eq!(task.project_id.as_deref(), Some(" Acme/Widgets "));
    }

    #[test]
    fn non_repository_provider_project_is_not_an_execution_target() {
        let task = external_task(ExternalProvider::Todoist, Some("project-17"));

        assert_eq!(execution_repository_for_task(&task), None);
    }

    #[test]
    fn explicit_execution_repository_wins_over_legacy_project_identity() {
        let mut item = TaskBoardItem::new(
            "task-1".into(),
            "Task".into(),
            String::new(),
            "2026-07-15T00:00:00Z".into(),
        );
        item.project_id = Some("acme/source".into());
        item.execution_repository = Some("acme/target".into());

        assert_eq!(github_repository_for_item(&item), Some("acme/target"));
    }

    fn external_task(provider: ExternalProvider, project_id: Option<&str>) -> ExternalTask {
        ExternalTask {
            reference: ExternalTaskRef::new(provider, "remote-1"),
            title: "Task".into(),
            body: String::new(),
            status: TaskBoardStatus::Todo,
            project_id: project_id.map(ToOwned::to_owned),
            updated_at: None,
        }
    }
}
