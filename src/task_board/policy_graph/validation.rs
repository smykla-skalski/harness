use std::collections::{HashMap, HashSet};

use super::{
    POLICY_GRAPH_SCHEMA_VERSION, PolicyAction, PolicyGraph, PolicyGraphEdgeCondition,
    PolicyGraphNode, PolicyGraphNodeKind, PolicyGraphPortDirection, PolicyGraphValidationIssue,
    PolicyGraphValidationReport, UNSAFE_HIGH_RISK_ACTIONS,
};

pub(super) fn validate(graph: &PolicyGraph) -> PolicyGraphValidationReport {
    let mut issues = Vec::new();
    if graph.schema_version != POLICY_GRAPH_SCHEMA_VERSION {
        issues.push(PolicyGraphValidationIssue::UnsupportedSchemaVersion {
            expected: POLICY_GRAPH_SCHEMA_VERSION,
            actual: graph.schema_version,
        });
    }

    issues.extend(duplicate_ids(graph));
    let nodes_by_id: HashMap<&str, &PolicyGraphNode> = graph
        .nodes
        .iter()
        .map(|node| (node.id.as_str(), node))
        .collect();
    issues.extend(edge_reference_issues(graph, &nodes_by_id));
    issues.extend(cycle_issues(graph, &nodes_by_id));
    issues.extend(unsafe_action_issues(graph, &nodes_by_id));
    PolicyGraphValidationReport { issues }
}

fn duplicate_ids(graph: &PolicyGraph) -> Vec<PolicyGraphValidationIssue> {
    let mut seen = HashSet::new();
    let mut issues = Vec::new();
    for node in &graph.nodes {
        if !seen.insert(format!("node:{}", node.id)) {
            issues.push(PolicyGraphValidationIssue::DuplicateId {
                id: node.id.clone(),
                location: "nodes".to_string(),
            });
        }
    }
    for edge in &graph.edges {
        if !seen.insert(format!("edge:{}", edge.id)) {
            issues.push(PolicyGraphValidationIssue::DuplicateId {
                id: edge.id.clone(),
                location: "edges".to_string(),
            });
        }
    }
    for group in &graph.groups {
        if !seen.insert(format!("group:{}", group.id)) {
            issues.push(PolicyGraphValidationIssue::DuplicateId {
                id: group.id.clone(),
                location: "groups".to_string(),
            });
        }
    }
    issues
}

fn edge_reference_issues(
    graph: &PolicyGraph,
    nodes_by_id: &HashMap<&str, &PolicyGraphNode>,
) -> Vec<PolicyGraphValidationIssue> {
    let mut issues = Vec::new();
    for edge in &graph.edges {
        let Some(from_node) = nodes_by_id.get(edge.from_node.as_str()) else {
            issues.push(PolicyGraphValidationIssue::DanglingEdge {
                edge_id: edge.id.clone(),
                node_id: edge.from_node.clone(),
            });
            continue;
        };
        let Some(to_node) = nodes_by_id.get(edge.to_node.as_str()) else {
            issues.push(PolicyGraphValidationIssue::DanglingEdge {
                edge_id: edge.id.clone(),
                node_id: edge.to_node.clone(),
            });
            continue;
        };
        if !port_exists(&from_node.output_ports, &edge.from_port) {
            issues.push(PolicyGraphValidationIssue::InvalidPort {
                edge_id: edge.id.clone(),
                node_id: edge.from_node.clone(),
                port: edge.from_port.clone(),
                direction: PolicyGraphPortDirection::Output,
            });
        }
        if !port_exists(&to_node.input_ports, &edge.to_port) {
            issues.push(PolicyGraphValidationIssue::InvalidPort {
                edge_id: edge.id.clone(),
                node_id: edge.to_node.clone(),
                port: edge.to_port.clone(),
                direction: PolicyGraphPortDirection::Input,
            });
        }
    }
    issues
}

fn port_exists(ports: &[String], port: &str) -> bool {
    ports.iter().any(|candidate| candidate == port)
}

fn cycle_issues(
    graph: &PolicyGraph,
    nodes_by_id: &HashMap<&str, &PolicyGraphNode>,
) -> Vec<PolicyGraphValidationIssue> {
    let mut visiting = HashSet::new();
    let mut visited = HashSet::new();
    let mut stack = Vec::new();
    for node in nodes_by_id.keys() {
        if find_cycle(node, graph, &mut visiting, &mut visited, &mut stack) {
            return vec![PolicyGraphValidationIssue::Cycle { node_ids: stack }];
        }
    }
    Vec::new()
}

fn find_cycle(
    node_id: &str,
    graph: &PolicyGraph,
    visiting: &mut HashSet<String>,
    visited: &mut HashSet<String>,
    stack: &mut Vec<String>,
) -> bool {
    if visited.contains(node_id) {
        return false;
    }
    if !visiting.insert(node_id.to_string()) {
        stack.push(node_id.to_string());
        return true;
    }
    stack.push(node_id.to_string());
    for edge in graph.edges.iter().filter(|edge| edge.from_node == node_id) {
        if find_cycle(&edge.to_node, graph, visiting, visited, stack) {
            return true;
        }
    }
    stack.pop();
    visiting.remove(node_id);
    visited.insert(node_id.to_string());
    false
}

fn unsafe_action_issues(
    graph: &PolicyGraph,
    nodes_by_id: &HashMap<&str, &PolicyGraphNode>,
) -> Vec<PolicyGraphValidationIssue> {
    let mut issues = Vec::new();
    for node in &graph.nodes {
        let PolicyGraphNodeKind::ActionGate { actions } = &node.kind else {
            continue;
        };
        for action in actions {
            if UNSAFE_HIGH_RISK_ACTIONS.contains(action)
                && !action_route_reaches_human_or_consensus(graph, nodes_by_id, &node.id, *action)
            {
                issues.push(PolicyGraphValidationIssue::UnsafeHighRiskAction { action: *action });
            }
        }
    }
    deduplicate_unsafe_actions(issues)
}

fn action_route_reaches_human_or_consensus(
    graph: &PolicyGraph,
    nodes_by_id: &HashMap<&str, &PolicyGraphNode>,
    action_node_id: &str,
    action: PolicyAction,
) -> bool {
    graph
        .edges
        .iter()
        .filter(|edge| {
            edge.from_node == action_node_id && edge_condition_contains_action(edge, action)
        })
        .any(|edge| can_reach_human_or_consensus(graph, nodes_by_id, &edge.to_node))
}

fn edge_condition_contains_action(edge: &super::PolicyGraphEdge, action: PolicyAction) -> bool {
    matches!(
        &edge.condition,
        PolicyGraphEdgeCondition::ActionIn { actions } if actions.contains(&action)
    ) || matches!(edge.condition, PolicyGraphEdgeCondition::Always)
}

fn can_reach_human_or_consensus(
    graph: &PolicyGraph,
    nodes_by_id: &HashMap<&str, &PolicyGraphNode>,
    start: &str,
) -> bool {
    let mut seen = HashSet::new();
    let mut stack = vec![start.to_string()];
    while let Some(node_id) = stack.pop() {
        if !seen.insert(node_id.clone()) {
            continue;
        }
        if let Some(node) = nodes_by_id.get(node_id.as_str())
            && matches!(
                node.kind,
                PolicyGraphNodeKind::HumanGate { .. } | PolicyGraphNodeKind::ConsensusGate { .. }
            )
        {
            return true;
        }
        stack.extend(
            graph
                .edges
                .iter()
                .filter(|edge| edge.from_node == node_id)
                .map(|edge| edge.to_node.clone()),
        );
    }
    false
}

fn deduplicate_unsafe_actions(
    issues: Vec<PolicyGraphValidationIssue>,
) -> Vec<PolicyGraphValidationIssue> {
    let mut seen = HashSet::new();
    issues
        .into_iter()
        .filter(|issue| match issue {
            PolicyGraphValidationIssue::UnsafeHighRiskAction { action } => {
                seen.insert(action_key(*action))
            }
            _ => true,
        })
        .collect()
}

const fn action_key(action: PolicyAction) -> &'static str {
    match action {
        PolicyAction::Sync => "sync",
        PolicyAction::Triage => "triage",
        PolicyAction::Plan => "plan",
        PolicyAction::SpawnAgent => "spawn_agent",
        PolicyAction::MutateRepo => "mutate_repo",
        PolicyAction::PushBranch => "push_branch",
        PolicyAction::OpenPr => "open_pr",
        PolicyAction::SubmitReview => "submit_review",
        PolicyAction::MergePr => "merge_pr",
        PolicyAction::DeleteWorktree => "delete_worktree",
        PolicyAction::StopAgent => "stop_agent",
        PolicyAction::AccessSecret => "access_secret",
        PolicyAction::DestructiveFs => "destructive_fs",
    }
}
