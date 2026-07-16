use std::collections::HashMap;
#[cfg(test)]
use std::path::Path;

use serde::{Deserialize, Serialize};

use super::dispatch::{DispatchPlan, build_dispatch_plans_with_policy};
#[cfg(test)]
use super::dispatch::{build_dispatch_plans, build_dispatch_plans_with_policy_root};
use super::external::{ExternalProvider, ExternalSyncConfig, ExternalSyncOperation};
use super::policy::PolicyApprovalGrant;
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
mod tests {
    use super::*;
    use crate::task_board::planning::{approve_plan, submit_plan};
    use crate::task_board::{PolicyAction, PolicyApprovalState, PolicyReasonCode};

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
            sync_state: None,
        });
        let config = ExternalSyncConfig {
            github_token: Some("token".into()),
            github_repository: None,
            github_inbox_repositories: Vec::new(),
            github_import_labels: Vec::new(),
            todoist_token: None,
            todoist_import_project_ids: Vec::new(),
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

    #[test]
    fn sync_summary_counts_github_repository_fallback_as_pushable() {
        let item = ready_item("task-1", "", AgentMode::Headless);
        let config = ExternalSyncConfig {
            github_token: Some("token".into()),
            github_repository: Some("owner/repo".into()),
            github_inbox_repositories: Vec::new(),
            github_import_labels: Vec::new(),
            todoist_token: None,
            todoist_import_project_ids: Vec::new(),
        };

        let summary = build_sync_summary(&[item], &config);
        let github = summary
            .providers
            .iter()
            .find(|entry| entry.provider == ExternalProvider::GitHub)
            .expect("github summary");

        assert!(github.configured);
        assert_eq!(github.pushable, 1);
        assert_eq!(github.blocked, 0);
    }

    #[test]
    fn audit_summary_counts_human_required_items() {
        let mut item = TaskBoardItem::new(
            "task-1".into(),
            "Review request".into(),
            "Needs attention".into(),
            "2026-05-14T00:00:00Z".into(),
        );
        item.status = TaskBoardStatus::HumanRequired;

        let summary = build_audit_summary(&[item]);
        let count = summary
            .by_status
            .iter()
            .find(|entry| entry.status == TaskBoardStatus::HumanRequired)
            .expect("human-required count");

        assert_eq!(count.count, 1);
    }

    #[test]
    fn audit_summary_excludes_deleted_from_status_and_total() {
        let mut live = TaskBoardItem::new(
            "task-live".into(),
            "Live".into(),
            String::new(),
            "2026-05-14T00:00:00Z".into(),
        );
        live.status = TaskBoardStatus::Todo;

        let mut tombstoned = TaskBoardItem::new(
            "task-deleted".into(),
            "Tombstone".into(),
            String::new(),
            "2026-05-14T00:00:00Z".into(),
        );
        tombstoned.status = TaskBoardStatus::Todo;
        tombstoned.deleted_at = Some("2026-05-14T02:00:00Z".into());

        let summary = build_audit_summary(&[live, tombstoned]);

        assert_eq!(summary.total, 1);
        assert_eq!(summary.deleted, 1);
        let todo_count = summary
            .by_status
            .iter()
            .find(|entry| entry.status == TaskBoardStatus::Todo)
            .expect("todo count");
        assert_eq!(todo_count.count, 1);
    }

    #[test]
    fn audit_summary_counts_approved_gated_item_as_ready() {
        let item = ready_item("task-1", "owner/repo", AgentMode::Headless);
        let graph = approval_spawn_graph();
        let grant = PolicyApprovalGrant {
            id: "grant-1".into(),
            board_item_id: item.id.clone(),
            action: PolicyAction::SpawnAgent,
            canvas_id: Some("canvas-1".into()),
            canvas_revision: graph.revision,
            node_id: "approve-spawn".into(),
            reason_code: PolicyReasonCode::ApprovalRequired,
            state: PolicyApprovalState::Approved,
            resolved_by: Some("operator".into()),
            resolved_at: Some("2026-07-14T00:00:01Z".into()),
            consumed_at: None,
            expiry_seconds: None,
            created_at: "2026-07-14T00:00:00Z".into(),
            updated_at: "2026-07-14T00:00:01Z".into(),
        };
        let grants = HashMap::from([(item.id.clone(), grant)]);

        let summary = build_audit_summary_with_policy(
            &[item],
            Some(("canvas-1", &graph)),
            "2026-07-14T00:00:02Z",
            super::super::dispatch::SpawnGateSwitches::default(),
            &grants,
        );

        assert_eq!(summary.ready, 1);
        assert_eq!(summary.blocked, 0);
    }

    fn approval_spawn_graph() -> super::super::policy_graph::PolicyGraph {
        serde_json::from_value(serde_json::json!({
            "schema_version": 2,
            "revision": 1,
            "mode": "enforced",
            "nodes": [
                {
                    "id": "gate-spawn",
                    "label": "Spawn gate",
                    "kind": { "kind": "action_gate", "actions": ["spawn_agent"] },
                    "input_ports": ["in"],
                    "output_ports": ["match", "default"]
                },
                {
                    "id": "approve-spawn",
                    "label": "Approve spawn",
                    "kind": { "kind": "approval_gate", "reason_code": "approval_required" },
                    "input_ports": ["in"],
                    "output_ports": ["approved"]
                },
                {
                    "id": "finish-allow",
                    "label": "Allow",
                    "kind": { "kind": "finish", "decision": "allow", "reason_code": "default_allow" },
                    "input_ports": ["in"],
                    "output_ports": []
                }
            ],
            "edges": [
                {
                    "id": "edge-gate-to-approval",
                    "from_node": "gate-spawn",
                    "from_port": "match",
                    "to_node": "approve-spawn",
                    "to_port": "in",
                    "condition": { "condition": "action_in", "actions": ["spawn_agent"] }
                },
                {
                    "id": "edge-approval-to-finish",
                    "from_node": "approve-spawn",
                    "from_port": "approved",
                    "to_node": "finish-allow",
                    "to_port": "in",
                    "condition": { "condition": "always" }
                }
            ],
            "groups": [],
            "layout": {}
        }))
        .expect("approval spawn graph")
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
