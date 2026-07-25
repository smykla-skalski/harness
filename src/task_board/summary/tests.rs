use super::*;
use crate::task_board::planning::{approve_plan, submit_plan};
use crate::task_board::{PolicyAction, PolicyApprovalState, PolicyReasonCode};

#[test]
fn summaries_group_projects_and_modes() {
    let project = registered_project("owner/repo");
    let item = ready_item("task-1", &project.project_id, AgentMode::Interactive);
    let second = ready_item("task-2", &project.project_id, AgentMode::Headless);

    let projects =
        build_project_summaries(&[item.clone(), second.clone()], std::slice::from_ref(&project));
    let machines = build_machine_summaries(&[item, second]);

    assert_eq!(projects[0].project_id, project.project_id);
    assert_eq!(projects[0].slug, "owner/repo");
    assert_eq!(projects[0].item_count, 2);
    assert_eq!(projects[0].ready_count, 2);
    assert_eq!(machines.len(), 2);
}

#[test]
fn a_registered_project_with_no_items_still_appears_in_the_catalog() {
    let project = registered_project("owner/quiet");

    let projects = build_project_summaries(&[], std::slice::from_ref(&project));

    assert_eq!(projects.len(), 1, "Settings lists projects, not just busy ones");
    assert_eq!(projects[0].item_count, 0);
    assert_eq!(projects[0].ready_count, 0);
}

fn registered_project(slug: &str) -> TaskBoardProject {
    TaskBoardProject {
        project_id: TaskBoardProject::generate_id(),
        source: TaskBoardProjectSource::GitHub,
        slug: slug.into(),
        display_name: None,
        color: crate::task_board::project_color::TaskBoardProjectColor::Blue,
        shape: crate::task_board::project_shape::TaskBoardProjectShape::DEFAULT,
        created_at: "2026-05-14T00:00:00Z".into(),
        updated_at: "2026-05-14T00:00:00Z".into(),
    }
}

#[test]
fn sync_summary_counts_provider_readiness() {
    // GitHub push readiness reads the provider-side project, not the board
    // attribution, so these fixtures have to carry both.
    let mut linked = ready_item("task-1", "project-owner-repo", AgentMode::Headless);
    linked.project_id = Some("owner/repo".into());
    linked.external_refs.push(super::super::types::ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "owner/repo#1".into(),
        url: None,
        sync_state: None,
    });

    // An item is counted as linked or pushable, never both, so proving the two
    // counters apart needs a second item that has a target but no reference.
    let mut pushable = ready_item("task-2", "project-owner-repo", AgentMode::Headless);
    pushable.project_id = Some("owner/repo".into());

    let config = ExternalSyncConfig {
        github_token: Some("token".into()),
        github_repository: None,
        github_inbox_repositories: Vec::new(),
        github_import_labels: Vec::new(),
    };

    let summary = build_sync_summary(&[linked, pushable], &config);
    let github = summary
        .providers
        .iter()
        .find(|entry| entry.provider == ExternalProvider::GitHub)
        .expect("github summary");

    assert!(github.configured);
    assert_eq!(github.linked, 1);
    assert_eq!(github.pushable, 1);
    assert_eq!(github.blocked, 0);
}

#[test]
fn sync_summary_counts_github_repository_fallback_as_pushable() {
    let item = ready_item("task-1", "", AgentMode::Headless);
    let config = ExternalSyncConfig {
        github_token: Some("token".into()),
        github_repository: Some("owner/repo".into()),
        github_inbox_repositories: Vec::new(),
        github_import_labels: Vec::new(),
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

fn ready_item(id: &str, source_project_id: &str, mode: AgentMode) -> TaskBoardItem {
    let item = TaskBoardItem::new(
        id.into(),
        "Task".into(),
        "Body".into(),
        "2026-05-14T00:00:00Z".into(),
    );
    let item = submit_plan(&item, "plan").apply_to(&item);
    let mut item = approve_plan(&item, "lead", "2026-05-14T01:00:00Z").apply_to(&item);
    item.source_project_id = Some(source_project_id.into());
    item.agent_mode = mode;
    item
}
