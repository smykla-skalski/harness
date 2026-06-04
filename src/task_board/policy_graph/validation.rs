use std::collections::{HashMap, HashSet};

use super::{
    POLICY_GRAPH_SCHEMA_VERSION, PORT_IMAGE, PORT_IN, PORT_PULL_REQUESTS, PORT_TEXT, PolicyAction,
    PolicyGraph, PolicyGraphEdge, PolicyGraphEdgeCondition, PolicyGraphNode, PolicyGraphNodeKind,
    PolicyGraphPortDirection, PolicyGraphValidationIssue, PolicyGraphValidationReport,
    UNSAFE_HIGH_RISK_ACTIONS,
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
    issues.extend(payload_compatibility_issues(graph, &nodes_by_id));
    issues.extend(cycle_issues(graph, &nodes_by_id));
    issues.extend(unsafe_action_issues(graph, &nodes_by_id));
    PolicyGraphValidationReport { issues }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PayloadKind {
    Event,
    Image,
    Text,
    PullRequests,
    Unknown,
}

impl PayloadKind {
    const fn id(self) -> &'static str {
        match self {
            Self::Event => "event",
            Self::Image => "image",
            Self::Text => "text",
            Self::PullRequests => "pull_requests",
            Self::Unknown => "unknown",
        }
    }

    const fn is_compatible_with(self, required: Self) -> bool {
        matches!(self, Self::Unknown)
            || matches!(required, Self::Unknown)
            || self as u8 == required as u8
    }
}

fn payload_compatibility_issues(
    graph: &PolicyGraph,
    nodes_by_id: &HashMap<&str, &PolicyGraphNode>,
) -> Vec<PolicyGraphValidationIssue> {
    let mut issues = Vec::new();
    for edge in &graph.edges {
        let Some(target_node) = nodes_by_id.get(edge.to_node.as_str()) else {
            continue;
        };
        if !nodes_by_id.contains_key(edge.from_node.as_str()) {
            continue;
        }
        let provided = payload_provided_by_edge(graph, nodes_by_id, edge, &mut HashSet::new());
        let required = payload_required_by_node(target_node);
        if !provided.is_compatible_with(required) {
            issues.push(PolicyGraphValidationIssue::IncompatiblePayloadEdge {
                edge_id: edge.id.clone(),
                provided: provided.id().to_string(),
                required: required.id().to_string(),
            });
        }
        if matches!(target_node.kind, PolicyGraphNodeKind::Hub) {
            issues.extend(hub_input_payload_issues(graph, nodes_by_id, target_node));
        }
    }
    deduplicate_payload_issues(issues)
}

fn hub_input_payload_issues(
    graph: &PolicyGraph,
    nodes_by_id: &HashMap<&str, &PolicyGraphNode>,
    hub: &PolicyGraphNode,
) -> Vec<PolicyGraphValidationIssue> {
    let incoming: Vec<_> = graph
        .edges
        .iter()
        .filter(|edge| edge.to_node == hub.id)
        .collect();
    let Some(first_edge) = incoming.first() else {
        return Vec::new();
    };
    let first_payload =
        payload_provided_by_edge(graph, nodes_by_id, first_edge, &mut HashSet::new());
    incoming
        .into_iter()
        .skip(1)
        .filter_map(|edge| {
            let payload = payload_provided_by_edge(graph, nodes_by_id, edge, &mut HashSet::new());
            (!payload.is_compatible_with(first_payload)).then(|| {
                PolicyGraphValidationIssue::IncompatiblePayloadEdge {
                    edge_id: edge.id.clone(),
                    provided: payload.id().to_string(),
                    required: first_payload.id().to_string(),
                }
            })
        })
        .collect()
}

fn payload_provided_by_edge(
    graph: &PolicyGraph,
    nodes_by_id: &HashMap<&str, &PolicyGraphNode>,
    edge: &PolicyGraphEdge,
    visited_hubs: &mut HashSet<String>,
) -> PayloadKind {
    let Some(source_node) = nodes_by_id.get(edge.from_node.as_str()) else {
        return PayloadKind::Unknown;
    };
    if matches!(source_node.kind, PolicyGraphNodeKind::Hub) {
        return hub_input_payload(graph, nodes_by_id, source_node, visited_hubs);
    }
    payload_from_port(&edge.from_port).unwrap_or_else(|| payload_produced_by_node(source_node))
}

fn hub_input_payload(
    graph: &PolicyGraph,
    nodes_by_id: &HashMap<&str, &PolicyGraphNode>,
    hub: &PolicyGraphNode,
    visited_hubs: &mut HashSet<String>,
) -> PayloadKind {
    if !visited_hubs.insert(hub.id.clone()) {
        return PayloadKind::Unknown;
    }
    graph
        .edges
        .iter()
        .filter(|edge| edge.to_node == hub.id)
        .map(|edge| payload_provided_by_edge(graph, nodes_by_id, edge, visited_hubs))
        .find(|payload| !matches!(payload, PayloadKind::Unknown))
        .unwrap_or(PayloadKind::Unknown)
}

fn payload_required_by_node(node: &PolicyGraphNode) -> PayloadKind {
    match &node.kind {
        PolicyGraphNodeKind::OcrImage => PayloadKind::Image,
        PolicyGraphNodeKind::ResolveReviewPullRequests => PayloadKind::Text,
        PolicyGraphNodeKind::CopyReviewPullRequestList => PayloadKind::PullRequests,
        PolicyGraphNodeKind::ActionStep(_) => payload_required_by_automation(node),
        _ => PayloadKind::Unknown,
    }
}

fn payload_produced_by_node(node: &PolicyGraphNode) -> PayloadKind {
    match &node.kind {
        PolicyGraphNodeKind::Trigger { .. } | PolicyGraphNodeKind::WorkflowEntry(_) => {
            PayloadKind::Event
        }
        PolicyGraphNodeKind::ReviewScreenshotPaste => PayloadKind::Image,
        PolicyGraphNodeKind::OcrImage => PayloadKind::Text,
        PolicyGraphNodeKind::ResolveReviewPullRequests => PayloadKind::PullRequests,
        _ => PayloadKind::Unknown,
    }
}

fn payload_required_by_automation(node: &PolicyGraphNode) -> PayloadKind {
    let Some(binding) = &node.automation else {
        return PayloadKind::Unknown;
    };
    let actions: HashSet<&str> = binding.actions.iter().map(String::as_str).collect();
    let postprocessors: HashSet<&str> = binding.postprocessors.iter().map(String::as_str).collect();
    if actions.contains("ocrImage") {
        return PayloadKind::Image;
    }
    if actions.contains("extractGitHubPullRequests")
        || actions.contains("resolveReviewPullRequests")
        || actions.contains("copyExtractedGitHubPullRequestURLs")
    {
        return PayloadKind::Text;
    }
    if actions.contains("copyReviewPullRequestList")
        || actions.contains("previewReviewApprovals")
        || actions.contains("promptReviewApprovals")
        || actions.contains("approveReviewPullRequests")
        || actions.contains("runReviewPolicy")
    {
        return PayloadKind::PullRequests;
    }
    if actions.contains("openDashboardDebugging")
        || actions.contains("rememberRecentScan")
        || actions.contains("showFeedback")
        || postprocessors.contains("persistResult")
    {
        return PayloadKind::Text;
    }
    PayloadKind::Unknown
}

fn payload_from_port(port: &str) -> Option<PayloadKind> {
    match port {
        PORT_IMAGE => Some(PayloadKind::Image),
        PORT_TEXT => Some(PayloadKind::Text),
        PORT_PULL_REQUESTS => Some(PayloadKind::PullRequests),
        PORT_IN => None,
        "event" => Some(PayloadKind::Event),
        _ => None,
    }
}

fn deduplicate_payload_issues(
    issues: Vec<PolicyGraphValidationIssue>,
) -> Vec<PolicyGraphValidationIssue> {
    let mut seen = HashSet::new();
    issues
        .into_iter()
        .filter(|issue| match issue {
            PolicyGraphValidationIssue::IncompatiblePayloadEdge { edge_id, .. } => {
                seen.insert(edge_id.clone())
            }
            _ => true,
        })
        .collect()
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
