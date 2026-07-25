use std::collections::HashMap;
#[cfg(test)]
use std::path::Path;

use serde::{Deserialize, Serialize};

use super::dispatch::{DispatchPlan, build_dispatch_plans_with_policy};
#[cfg(test)]
use super::dispatch::{build_dispatch_plans, build_dispatch_plans_with_policy_root};
use super::external::{ExternalProvider, ExternalSyncConfig, ExternalSyncOperation};
use super::policy::PolicyApprovalGrant;
use super::project::{TaskBoardProject, TaskBoardProjectSource};
use super::project_color::TaskBoardProjectColor;
use super::project_shape::TaskBoardProjectShape;
use super::types::{AgentMode, ExternalRefProvider, TaskBoardItem, TaskBoardStatus};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardAuditSummary {
    pub total: usize,
    pub ready: usize,
    pub blocked: usize,
    pub deleted: usize,
    pub by_status: Vec<TaskBoardStatusCount>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardStatusCount {
    pub status: TaskBoardStatus,
    pub count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardSyncSummary {
    pub total: usize,
    pub providers: Vec<TaskBoardProviderSyncSummary>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub operations: Vec<ExternalSyncOperation>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardProviderSyncSummary {
    pub provider: ExternalProvider,
    pub configured: bool,
    pub linked: usize,
    pub pushable: usize,
    pub blocked: usize,
    pub token_env: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardProjectSummary {
    pub project_id: String,
    pub source: TaskBoardProjectSource,
    pub slug: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    pub color: TaskBoardProjectColor,
    pub shape: TaskBoardProjectShape,
    pub item_count: usize,
    pub ready_count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardMachineSummary {
    pub mode: AgentMode,
    pub item_count: usize,
    pub ready_count: usize,
}

#[must_use]
#[cfg(test)]
pub fn build_audit_summary(items: &[TaskBoardItem]) -> TaskBoardAuditSummary {
    let plans = build_dispatch_plans(items);
    audit_summary(items, &plans)
}

#[must_use]
pub(crate) fn build_audit_summary_with_policy(
    items: &[TaskBoardItem],
    policy: Option<(&str, &super::policy_graph::PolicyGraph)>,
    evaluated_at: &str,
    switches: super::dispatch::SpawnGateSwitches,
    grants: &HashMap<String, PolicyApprovalGrant>,
) -> TaskBoardAuditSummary {
    let plans =
        build_dispatch_plans_with_policy(items, policy, Some(evaluated_at), switches, grants);
    audit_summary(items, &plans)
}

fn audit_summary(items: &[TaskBoardItem], plans: &[DispatchPlan]) -> TaskBoardAuditSummary {
    TaskBoardAuditSummary {
        total: items.iter().filter(|item| !item.is_deleted()).count(),
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
#[cfg(test)]
pub fn build_dispatch_summary(items: &[TaskBoardItem]) -> Vec<DispatchPlan> {
    build_dispatch_plans(items)
}

#[must_use]
#[cfg(test)]
pub fn build_dispatch_summary_with_policy_root(
    items: &[TaskBoardItem],
    policy_root: &Path,
) -> Vec<DispatchPlan> {
    build_dispatch_plans_with_policy_root(items, policy_root)
}

/// Every registered project with how much work it holds. A project with no
/// items still appears, because the catalog is what Settings lists and a
/// freshly added project has nothing attached to it yet.
#[must_use]
pub fn build_project_summaries(
    items: &[TaskBoardItem],
    projects: &[TaskBoardProject],
) -> Vec<TaskBoardProjectSummary> {
    let mut summaries: Vec<TaskBoardProjectSummary> = projects
        .iter()
        .map(|project| TaskBoardProjectSummary {
            project_id: project.project_id.clone(),
            source: project.source,
            slug: project.slug.clone(),
            display_name: project.display_name.clone(),
            color: project.color,
            shape: project.shape,
            item_count: 0,
            ready_count: 0,
        })
        .collect();
    // Indexed rather than scanned: a board with many items across many
    // projects would otherwise cost items x projects on every catalog read.
    // Built from `projects` because `summaries` is about to be mutated, and
    // the two share an order.
    let index: HashMap<&str, usize> = projects
        .iter()
        .enumerate()
        .map(|(position, project)| (project.project_id.as_str(), position))
        .collect();
    for item in items.iter().filter(|item| !item.is_deleted()) {
        let Some(position) = item
            .source_project_id
            .as_deref()
            .and_then(|project_id| index.get(project_id).copied())
        else {
            continue;
        };
        let summary = &mut summaries[position];
        summary.item_count += 1;
        if item.status == TaskBoardStatus::Todo {
            summary.ready_count += 1;
        }
    }
    summaries.sort_by(|left, right| {
        left.source
            .as_str()
            .cmp(right.source.as_str())
            .then_with(|| left.slug.cmp(&right.slug))
    });
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
        } else if can_push_to_provider(item, provider, config) {
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

fn can_push_to_provider(
    item: &TaskBoardItem,
    provider: ExternalProvider,
    config: &ExternalSyncConfig,
) -> bool {
    match provider {
        ExternalProvider::GitHub => {
            item.project_id.as_deref().is_some_and(is_github_repo)
                || config.github_repository().is_some()
        }
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
        TaskBoardStatus::Backlog,
        TaskBoardStatus::Todo,
        TaskBoardStatus::Planning,
        TaskBoardStatus::InProgress,
        TaskBoardStatus::AgenticReview,
        TaskBoardStatus::Testing,
        TaskBoardStatus::InReview,
        TaskBoardStatus::ToReview,
        TaskBoardStatus::HumanRequired,
        TaskBoardStatus::Failed,
        TaskBoardStatus::Done,
        TaskBoardStatus::New,
        TaskBoardStatus::PlanReview,
        TaskBoardStatus::NeedsYou,
        TaskBoardStatus::Blocked,
    ];
    statuses
        .into_iter()
        .map(|status| TaskBoardStatusCount {
            status,
            count: items
                .iter()
                .filter(|item| !item.is_deleted() && item.status == status)
                .count(),
        })
        .filter(|entry| entry.count > 0)
        .collect()
}

#[cfg(test)]
mod tests;
