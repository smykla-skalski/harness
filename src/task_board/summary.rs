use serde::{Deserialize, Serialize};

use super::dispatch::{DispatchPlan, build_dispatch_plans};
use super::external::{ExternalProvider, ExternalSyncConfig, ExternalSyncOperation};
use super::types::{AgentMode, ExternalRefProvider, TaskBoardItem, TaskBoardStatus};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardAuditSummary {
    pub total: usize,
    pub ready: usize,
    pub blocked: usize,
    pub deleted: usize,
    pub by_status: Vec<TaskBoardStatusCount>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardStatusCount {
    pub status: TaskBoardStatus,
    pub count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardSyncSummary {
    pub total: usize,
    pub providers: Vec<TaskBoardProviderSyncSummary>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub operations: Vec<ExternalSyncOperation>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardProviderSyncSummary {
    pub provider: ExternalProvider,
    pub configured: bool,
    pub linked: usize,
    pub pushable: usize,
    pub blocked: usize,
    pub token_env: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardProjectSummary {
    pub project_id: String,
    pub item_count: usize,
    pub ready_count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardMachineSummary {
    pub mode: AgentMode,
    pub item_count: usize,
    pub ready_count: usize,
}

#[must_use]
pub fn build_audit_summary(items: &[TaskBoardItem]) -> TaskBoardAuditSummary {
    let plans = build_dispatch_plans(items);
    TaskBoardAuditSummary {
        total: items.len(),
        ready: plans.iter().filter(|plan| plan.is_ready()).count(),
        blocked: plans.iter().filter(|plan| !plan.is_ready()).count(),
        deleted: items.iter().filter(|item| item.is_deleted()).count(),
        by_status: status_counts(items),
    }
}

#[must_use]
pub fn build_sync_summary(
    items: &[TaskBoardItem],
    config: &ExternalSyncConfig,
) -> TaskBoardSyncSummary {
    let providers = [ExternalProvider::GitHub, ExternalProvider::Todoist]
        .into_iter()
        .map(|provider| provider_sync_summary(items, config, provider))
        .collect();
    TaskBoardSyncSummary {
        total: items.len(),
        providers,
        operations: Vec::new(),
    }
}

#[must_use]
pub fn build_dispatch_summary(items: &[TaskBoardItem]) -> Vec<DispatchPlan> {
    build_dispatch_plans(items)
}

#[must_use]
pub fn build_project_summaries(items: &[TaskBoardItem]) -> Vec<TaskBoardProjectSummary> {
    let mut summaries = Vec::<TaskBoardProjectSummary>::new();
    for item in items.iter().filter(|item| !item.is_deleted()) {
        let Some(project_id) = item.project_id.as_deref() else {
            continue;
        };
        match summaries
            .iter_mut()
            .find(|summary| summary.project_id == project_id)
        {
            Some(summary) => {
                summary.item_count += 1;
                if item.status == TaskBoardStatus::Todo {
                    summary.ready_count += 1;
                }
            }
            None => summaries.push(TaskBoardProjectSummary {
                project_id: project_id.to_owned(),
                item_count: 1,
                ready_count: usize::from(item.status == TaskBoardStatus::Todo),
            }),
        }
    }
    summaries.sort_by(|left, right| left.project_id.cmp(&right.project_id));
    summaries
}

#[must_use]
pub fn build_machine_summaries(items: &[TaskBoardItem]) -> Vec<TaskBoardMachineSummary> {
    let modes = [
        AgentMode::Headless,
        AgentMode::Interactive,
        AgentMode::Planning,
        AgentMode::Evaluate,
    ];
    modes
        .into_iter()
        .filter_map(|mode| {
            let matching = items
                .iter()
                .filter(|item| !item.is_deleted() && item.agent_mode == mode);
            let mut item_count = 0;
            let mut ready_count = 0;
            for item in matching {
                item_count += 1;
                if item.status == TaskBoardStatus::Todo {
                    ready_count += 1;
                }
            }
            (item_count > 0).then_some(TaskBoardMachineSummary {
                mode,
                item_count,
                ready_count,
            })
        })
        .collect()
}

fn provider_sync_summary(
    items: &[TaskBoardItem],
    config: &ExternalSyncConfig,
    provider: ExternalProvider,
) -> TaskBoardProviderSyncSummary {
    let ref_provider = ExternalRefProvider::from(provider);
    let mut linked = 0;
    let mut pushable = 0;
    let mut blocked = 0;
    for item in items.iter().filter(|item| !item.is_deleted()) {
        if item
            .external_refs
            .iter()
            .any(|reference| reference.provider == ref_provider)
        {
            linked += 1;
        } else if can_push_to_provider(item, provider) {
            pushable += 1;
        } else {
            blocked += 1;
        }
    }
    TaskBoardProviderSyncSummary {
        provider,
        configured: config.token_for(provider).is_some(),
        linked,
        pushable,
        blocked,
        token_env: provider
            .token_env_names()
            .iter()
            .map(ToString::to_string)
            .collect(),
    }
}

fn can_push_to_provider(item: &TaskBoardItem, provider: ExternalProvider) -> bool {
    match provider {
        ExternalProvider::GitHub => item.project_id.as_deref().is_some_and(is_github_repo),
        ExternalProvider::Todoist => true,
    }
}

fn is_github_repo(project_id: &str) -> bool {
    let mut parts = project_id.split('/');
    matches!(
        (parts.next(), parts.next(), parts.next()),
        (Some(owner), Some(repo), None) if !owner.is_empty() && !repo.is_empty()
    )
}

fn status_counts(items: &[TaskBoardItem]) -> Vec<TaskBoardStatusCount> {
    let statuses = [
        TaskBoardStatus::New,
        TaskBoardStatus::Planning,
        TaskBoardStatus::PlanReview,
        TaskBoardStatus::Todo,
        TaskBoardStatus::InProgress,
        TaskBoardStatus::InReview,
        TaskBoardStatus::Done,
        TaskBoardStatus::Blocked,
    ];
    statuses
        .into_iter()
        .map(|status| TaskBoardStatusCount {
            status,
            count: items.iter().filter(|item| item.status == status).count(),
        })
        .filter(|entry| entry.count > 0)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::planning::{approve_plan, submit_plan};

    #[test]
    fn summaries_group_projects_and_modes() {
        let item = ready_item("task-1", "owner/repo", AgentMode::Interactive);
        let second = ready_item("task-2", "owner/repo", AgentMode::Headless);

        let projects = build_project_summaries(&[item.clone(), second.clone()]);
        let machines = build_machine_summaries(&[item, second]);

        assert_eq!(projects[0].project_id, "owner/repo");
        assert_eq!(projects[0].item_count, 2);
        assert_eq!(projects[0].ready_count, 2);
        assert_eq!(machines.len(), 2);
    }

    #[test]
    fn sync_summary_counts_provider_readiness() {
        let mut item = ready_item("task-1", "owner/repo", AgentMode::Headless);
        item.external_refs.push(super::super::types::ExternalRef {
            provider: ExternalRefProvider::Todoist,
            external_id: "remote-1".into(),
            url: None,
        });
        let config = ExternalSyncConfig {
            github_token: Some("token".into()),
            github_repository: None,
            todoist_token: None,
        };

        let summary = build_sync_summary(&[item], &config);
        let github = summary
            .providers
            .iter()
            .find(|entry| entry.provider == ExternalProvider::GitHub)
            .expect("github summary");
        let todoist = summary
            .providers
            .iter()
            .find(|entry| entry.provider == ExternalProvider::Todoist)
            .expect("todoist summary");

        assert!(github.configured);
        assert_eq!(github.pushable, 1);
        assert!(!todoist.configured);
        assert_eq!(todoist.linked, 1);
    }

    fn ready_item(id: &str, project_id: &str, mode: AgentMode) -> TaskBoardItem {
        let item = TaskBoardItem::new(
            id.into(),
            "Task".into(),
            "Body".into(),
            "2026-05-14T00:00:00Z".into(),
        );
        let item = submit_plan(&item, "plan").apply_to(&item);
        let mut item = approve_plan(&item, "lead", "2026-05-14T01:00:00Z").apply_to(&item);
        item.project_id = Some(project_id.into());
        item.agent_mode = mode;
        item
    }
}
