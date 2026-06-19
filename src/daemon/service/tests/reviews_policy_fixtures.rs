use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use serde_json::json;
use tempfile::tempdir;

use crate::reviews::policy::ReviewsPolicyActionExecutor;
use crate::reviews::{
    ReviewCheckStatus, ReviewMergeableState, ReviewPullRequestState, ReviewReviewStatus,
    ReviewTarget, ReviewTargetFlags,
};
use crate::task_board::github::GitHubMergeMethod;
use crate::task_board::policy::PolicyReasonCode;
use crate::task_board::policy_graph::{
    PORT_IN, PolicyActionStep, PolicyFinishNode, PolicyGraph, PolicyGraphDecision, PolicyGraphEdge,
    PolicyGraphEdgeCondition, PolicyGraphMode, PolicyGraphNode, PolicyGraphNodeId,
    PolicyGraphNodeKind, PolicyGraphNodeLayout, PolicyWaitCondition, PolicyWaitStep,
    PolicyWorkflowEntry, store_gate_policy,
};
use crate::task_board::policy_runtime::models::{
    PolicyActionDescriptor, PolicyRunRequest, PolicyRunStep, PolicyRunSubject,
};

pub(super) fn test_runtime_root() -> PathBuf {
    let temp = tempdir().expect("create tempdir");
    let root = temp.path().to_path_buf();
    std::mem::forget(temp);
    root
}

pub(super) fn review_target_fixture() -> ReviewTarget {
    ReviewTarget {
        pull_request_id: "pr_1272".to_owned(),
        repository_id: "repo_1".to_owned(),
        repository: "Kong/mink-vcp-manager".to_owned(),
        number: 1272,
        url: "https://github.com/Kong/mink-vcp-manager/pull/1272".to_owned(),
        state: ReviewPullRequestState::Open,
        head_sha: "abc123".to_owned(),
        mergeable: ReviewMergeableState::Mergeable,
        review_status: ReviewReviewStatus::ReviewRequired,
        check_status: ReviewCheckStatus::Success,
        flags: ReviewTargetFlags {
            is_draft: false,
            policy_blocked: false,
            viewer_can_update: true,
        },
        viewer_can_merge_as_admin: false,
        required_failed_check_names: Vec::new(),
        check_suite_ids: vec!["check-suite-1".to_owned()],
    }
}

pub(super) fn reviews_policy_run_request(
    target: ReviewTarget,
    method: GitHubMergeMethod,
    wait: PolicyWaitCondition,
) -> PolicyRunRequest {
    let merge_target = target.clone();
    PolicyRunRequest {
        workflow_id: "reviews_auto".to_owned(),
        subject: PolicyRunSubject::review_pr(&format!("{}#{}", target.repository, target.number)),
        subject_fingerprint: Some(target.head_sha.clone()),
        steps: vec![
            PolicyRunStep::Action(PolicyActionDescriptor {
                provider: "reviews".to_owned(),
                action_key: "reviews.approve".to_owned(),
                payload: Some(json!({
                    "target": target,
                    "merge_method": null,
                })),
            }),
            PolicyRunStep::Wait(wait),
            PolicyRunStep::Action(PolicyActionDescriptor {
                provider: "reviews".to_owned(),
                action_key: "reviews.merge".to_owned(),
                payload: Some(json!({
                    "target": merge_target,
                    "merge_method": method,
                })),
            }),
        ],
    }
}

pub(super) fn write_active_policy_graph(root: &PathBuf, graph: PolicyGraph) {
    store_gate_policy(root, Some(graph));
}

pub(super) fn approve_wait_merge_policy_graph() -> PolicyGraph {
    workflow_graph(vec![
        workflow_action_node("step-approve", "Approve", "reviews.approve", 180),
        workflow_wait_node(
            "step-wait-checks",
            "Wait for checks",
            PolicyWaitCondition::Event {
                event_key: "reviews.checks_passed".to_owned(),
            },
            "checks-ready",
            340,
        ),
        workflow_action_node("step-merge", "Merge", "reviews.merge", 500),
    ])
}

pub(super) fn merge_only_policy_graph() -> PolicyGraph {
    workflow_graph(vec![workflow_action_node(
        "step-merge",
        "Merge",
        "reviews.merge",
        180,
    )])
}

fn workflow_graph(mut workflow_nodes: Vec<PolicyGraphNode>) -> PolicyGraph {
    let mut graph = PolicyGraph::seeded_v2();
    graph.mode = PolicyGraphMode::Enforced;
    graph.nodes.clear();
    graph.edges.clear();
    graph.groups.clear();
    graph.layout.nodes.clear();

    graph.nodes.push(PolicyGraphNode {
        id: "entry-reviews-auto".into(),
        label: "Reviews Auto".to_owned(),
        kind: PolicyGraphNodeKind::WorkflowEntry(PolicyWorkflowEntry {
            workflow_id: "reviews_auto".to_owned(),
        }),
        automation: None,
        input_ports: vec![PORT_IN.into()],
        output_ports: vec!["out".into()],
        group_id: None,
    });
    graph.layout.nodes.push(PolicyGraphNodeLayout {
        node_id: "entry-reviews-auto".into(),
        x: 24,
        y: 24,
        source: None,
    });

    let mut previous_id = PolicyGraphNodeId::from("entry-reviews-auto");
    for node in workflow_nodes.drain(..) {
        let node_id = node.id.clone();
        graph.layout.nodes.push(PolicyGraphNodeLayout {
            node_id: node_id.clone(),
            x: graph.layout.nodes.len() as i32 * 160 + 24,
            y: 24,
            source: None,
        });
        graph.edges.push(PolicyGraphEdge {
            id: format!("edge:{previous_id}:{node_id}").into(),
            from_node: previous_id.clone(),
            from_port: "out".into(),
            to_node: node_id.clone(),
            to_port: PORT_IN.into(),
            label: None,
            condition: PolicyGraphEdgeCondition::Always,
        });
        previous_id = node_id;
        graph.nodes.push(node);
    }

    graph.nodes.push(PolicyGraphNode {
        id: "finish-allow".into(),
        label: "Finish".to_owned(),
        kind: PolicyGraphNodeKind::Finish(PolicyFinishNode {
            decision: PolicyGraphDecision::Allow,
            reason_code: PolicyReasonCode::DefaultAllow,
        }),
        automation: None,
        input_ports: vec![PORT_IN.into()],
        output_ports: Vec::new(),
        group_id: None,
    });
    graph.layout.nodes.push(PolicyGraphNodeLayout {
        node_id: "finish-allow".into(),
        x: graph.layout.nodes.len() as i32 * 160 + 24,
        y: 24,
        source: None,
    });
    graph.edges.push(PolicyGraphEdge {
        id: format!("edge:{previous_id}:finish-allow").into(),
        from_node: previous_id,
        from_port: "out".into(),
        to_node: "finish-allow".into(),
        to_port: PORT_IN.into(),
        label: None,
        condition: PolicyGraphEdgeCondition::Always,
    });

    graph
}

fn workflow_action_node(id: &str, label: &str, action_id: &str, x: i32) -> PolicyGraphNode {
    let _ = x;
    PolicyGraphNode {
        id: id.into(),
        label: label.to_owned(),
        kind: PolicyGraphNodeKind::ActionStep(PolicyActionStep {
            action_id: action_id.to_owned(),
        }),
        automation: None,
        input_ports: vec![PORT_IN.into()],
        output_ports: vec!["out".into()],
        group_id: None,
    }
}

fn workflow_wait_node(
    id: &str,
    label: &str,
    wait: PolicyWaitCondition,
    resume_key: &str,
    x: i32,
) -> PolicyGraphNode {
    let _ = x;
    PolicyGraphNode {
        id: id.into(),
        label: label.to_owned(),
        kind: PolicyGraphNodeKind::WaitStep(PolicyWaitStep {
            wait,
            resume_key: resume_key.to_owned(),
        }),
        automation: None,
        input_ports: vec![PORT_IN.into()],
        output_ports: vec!["out".into()],
        group_id: None,
    }
}

pub(super) struct TestReviewsPolicyExecutor {
    pub(super) recorded_actions: Arc<Mutex<Vec<String>>>,
}

#[async_trait]
impl ReviewsPolicyActionExecutor for TestReviewsPolicyExecutor {
    async fn approve(&self, _target: &ReviewTarget) -> Result<(), crate::errors::CliError> {
        self.recorded_actions
            .lock()
            .expect("lock recorded actions")
            .push("reviews.approve".to_owned());
        Ok(())
    }

    async fn merge(
        &self,
        _target: &ReviewTarget,
        _method: GitHubMergeMethod,
    ) -> Result<(), crate::errors::CliError> {
        self.recorded_actions
            .lock()
            .expect("lock recorded actions")
            .push("reviews.merge".to_owned());
        Ok(())
    }
}
