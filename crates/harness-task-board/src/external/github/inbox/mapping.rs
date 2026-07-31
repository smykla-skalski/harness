use std::collections::{BTreeSet, HashMap};

use crate::external::{ExternalProvider, ExternalTask, ExternalTaskRef};
use crate::types::{TaskBoardStatus, TaskBoardWorkflowKind};

use super::super::graphql::GitHubSearchIssuePullRequestItem;
use super::super::{
    GitHubRepository, body_lists_child_issues, github_external_id, github_inbox_issue_status,
    parent_reference_in_body, search_label_matches_filter,
};

pub(super) fn assigned_issue_tasks(
    repository: &GitHubRepository,
    import_labels: &[String],
    items: Vec<GitHubSearchIssuePullRequestItem>,
    body_loaded: bool,
) -> Vec<ExternalTask> {
    let project_id = repository.slug();
    items
        .into_iter()
        .filter(|item| search_label_matches_filter(&item.label_names(), import_labels))
        .map(|item| {
            let labels = item.label_names();
            let body = body_if_loaded(item.body, body_loaded);
            let parent_reference = body_loaded
                .then(|| parent_reference_in_body(repository, &body))
                .flatten();
            let tracks_children = body_loaded && body_lists_child_issues(&body);
            let mut task = ExternalTask {
                reference: github_task_ref(repository, item.number, item.url),
                title: item.title,
                body,
                status: github_inbox_issue_status(item.state.as_str()),
                project_id: Some(project_id.clone()),
                updated_at: Some(item.updated_at),
                labels,
                parent_reference,
                tracks_children,
                ..ExternalTask::default()
            };
            if !body_loaded {
                task.mark_body_unloaded();
            }
            task
        })
        .collect()
}

pub(super) fn review_request_tasks(
    repository: &GitHubRepository,
    import_labels: &[String],
    items: Vec<GitHubSearchIssuePullRequestItem>,
    body_loaded: bool,
) -> Vec<ExternalTask> {
    pull_request_tasks(
        repository,
        import_labels,
        items,
        TaskBoardWorkflowKind::PrReview,
        body_loaded,
    )
}

pub(super) fn dependency_update_tasks(
    repository: &GitHubRepository,
    import_labels: &[String],
    items: Vec<GitHubSearchIssuePullRequestItem>,
    body_loaded: bool,
) -> Vec<ExternalTask> {
    let mut seen = BTreeSet::new();
    pull_request_tasks(
        repository,
        import_labels,
        items
            .into_iter()
            .filter(|item| seen.insert(item.number))
            .collect(),
        TaskBoardWorkflowKind::PrFix,
        body_loaded,
    )
}

fn pull_request_tasks(
    repository: &GitHubRepository,
    import_labels: &[String],
    items: Vec<GitHubSearchIssuePullRequestItem>,
    workflow_kind: TaskBoardWorkflowKind,
    body_loaded: bool,
) -> Vec<ExternalTask> {
    let project_id = repository.slug();
    items
        .into_iter()
        .filter(|item| search_label_matches_filter(&item.label_names(), import_labels))
        .map(|item| {
            let labels = item.label_names();
            let pr_author = item.author_login().map(str::to_owned);
            let body = body_if_loaded(item.body, body_loaded);
            let parent_reference = body_loaded
                .then(|| parent_reference_in_body(repository, &body))
                .flatten();
            let tracks_children = body_loaded && body_lists_child_issues(&body);
            let mut task = ExternalTask {
                reference: github_task_ref(repository, item.number, item.url),
                title: item.title,
                body,
                status: TaskBoardStatus::Inbox,
                project_id: Some(project_id.clone()),
                updated_at: Some(item.updated_at),
                labels,
                parent_reference,
                tracks_children,
                workflow_kind,
                pr_head_revision: item.head_ref_oid,
                pr_author,
            };
            if !body_loaded {
                task.mark_body_unloaded();
            }
            task
        })
        .collect()
}

fn body_if_loaded(body: Option<String>, loaded: bool) -> String {
    if loaded {
        body.unwrap_or_default()
    } else {
        String::new()
    }
}

pub(super) fn union_pull_request_intents(tasks: Vec<ExternalTask>) -> Vec<ExternalTask> {
    let mut order: Vec<String> = Vec::new();
    let mut by_id: HashMap<String, ExternalTask> = HashMap::new();
    for task in tasks {
        let id = task.reference.external_id.clone();
        if let Some(existing) = by_id.get_mut(&id) {
            existing.workflow_kind = existing.workflow_kind.union(task.workflow_kind);
            if existing.pr_head_revision.is_none() {
                existing.pr_head_revision = task.pr_head_revision;
            }
            if existing.pr_author.is_none() {
                existing.pr_author = task.pr_author;
            }
        } else {
            order.push(id.clone());
            by_id.insert(id, task);
        }
    }
    order
        .into_iter()
        .filter_map(|id| by_id.remove(&id))
        .collect()
}

fn github_task_ref(
    repository: &GitHubRepository,
    number: u64,
    html_url: String,
) -> ExternalTaskRef {
    ExternalTaskRef::new(
        ExternalProvider::GitHub,
        github_external_id(repository, number),
    )
    .with_url(html_url)
}
