//! Spawn-route terminal invariant.
//!
//! A `spawn_agent` input must never reach the evaluator's implicit
//! default-allow fall-through: every route the spawn action can walk has to end
//! at an explicit terminal node (Finish / SupervisorRule / HumanGate /
//! ConsensusGate / DryRunGate, or an ApprovalGate whose approved branch itself
//! reaches a terminal). This module walks the spawn-reachable subgraph and flags
//! any non-terminal node that dead-ends the route.

use std::collections::{HashSet, VecDeque};

use super::super::PORT_APPROVED;
use super::{
    PolicyAction, PolicyGraph, PolicyGraphEdge, PolicyGraphEdgeCondition, PolicyGraphNode,
    PolicyGraphNodeKind, PolicyGraphValidationIssue,
};

pub(super) fn spawn_route_issues(graph: &PolicyGraph) -> Vec<PolicyGraphValidationIssue> {
    // The invariant only applies to graphs that actually gate spawning. A graph
    // with no spawn-agent action gate (the review/OCR canvases) has no spawn
    // route to validate, so it is exempt.
    if !gates_spawn_agent(graph) {
        return Vec::new();
    }
    let Some(entry) = spawn_entry_node(graph) else {
        return Vec::new();
    };
    let mut issues = Vec::new();
    let mut seen: HashSet<&str> = HashSet::new();
    let mut pending: VecDeque<&str> = VecDeque::from([entry.id.as_str()]);
    while let Some(node_id) = pending.pop_front() {
        if !seen.insert(node_id) {
            continue;
        }
        let Some(node) = graph.nodes.iter().find(|node| node.id.as_str() == node_id) else {
            continue;
        };
        if is_terminal_kind(&node.kind) {
            continue;
        }
        let followed = followed_edges(graph, node);
        if followed.is_empty() {
            issues.push(PolicyGraphValidationIssue::SpawnRouteMissingTerminal {
                node_id: node_id.to_owned(),
            });
            continue;
        }
        pending.extend(followed.into_iter().map(|edge| edge.to_node.as_str()));
    }
    issues
}

/// Whether any action gate in the graph routes the spawn-agent action.
fn gates_spawn_agent(graph: &PolicyGraph) -> bool {
    graph.nodes.iter().any(|node| {
        matches!(
            &node.kind,
            PolicyGraphNodeKind::ActionGate { actions }
                if actions.contains(&PolicyAction::SpawnAgent)
        )
    })
}

/// The node a workflow-less spawn input enters, mirroring the evaluator's
/// fallback: the first node with no input ports, else the first action gate.
fn spawn_entry_node(graph: &PolicyGraph) -> Option<&PolicyGraphNode> {
    let workflow_nodes = workflow_subgraph(graph);
    graph
        .nodes
        .iter()
        .find(|node| node.input_ports.is_empty() && !workflow_nodes.contains(node.id.as_str()))
        .or_else(|| {
            graph.nodes.iter().find(|node| {
                matches!(node.kind, PolicyGraphNodeKind::ActionGate { .. })
                    && !workflow_nodes.contains(node.id.as_str())
            })
        })
}

fn workflow_subgraph(graph: &PolicyGraph) -> HashSet<String> {
    let mut nodes = HashSet::new();
    let mut pending: VecDeque<&str> = graph
        .nodes
        .iter()
        .filter(|node| {
            matches!(
                node.kind,
                PolicyGraphNodeKind::Trigger { .. } | PolicyGraphNodeKind::WorkflowEntry(_)
            )
        })
        .map(|node| node.id.as_str())
        .collect();
    while let Some(node_id) = pending.pop_front() {
        if !nodes.insert(node_id.to_owned()) {
            continue;
        }
        pending.extend(
            graph
                .edges
                .iter()
                .filter(|edge| edge.from_node.as_str() == node_id)
                .map(|edge| edge.to_node.as_str()),
        );
    }
    nodes
}

/// The edges the spawn route can follow out of `node`. Action gates follow only
/// the spawn-matching edge (or the always fallback); approval gates follow only
/// the approved output; every other non-terminal node follows all outgoing
/// edges because its branch depends on evidence unknown at validation time.
fn followed_edges<'a>(graph: &'a PolicyGraph, node: &PolicyGraphNode) -> Vec<&'a PolicyGraphEdge> {
    let outgoing = |predicate: &dyn Fn(&&PolicyGraphEdge) -> bool| -> Vec<&PolicyGraphEdge> {
        graph
            .edges
            .iter()
            .filter(|edge| edge.from_node == node.id)
            .filter(|edge| predicate(edge))
            .collect()
    };
    match &node.kind {
        PolicyGraphNodeKind::ActionGate { .. } => {
            let matched = outgoing(&|edge| {
                matches!(
                    &edge.condition,
                    PolicyGraphEdgeCondition::ActionIn { actions }
                        if actions.contains(&PolicyAction::SpawnAgent)
                )
            });
            if matched.is_empty() {
                outgoing(&|edge| matches!(edge.condition, PolicyGraphEdgeCondition::Always))
            } else {
                matched
            }
        }
        PolicyGraphNodeKind::ApprovalGate(_) => {
            outgoing(&|edge| edge.from_port.as_str() == PORT_APPROVED)
        }
        _ => outgoing(&|_| true),
    }
}

/// Terminal node kinds always return a decision, so they close a route.
const fn is_terminal_kind(kind: &PolicyGraphNodeKind) -> bool {
    matches!(
        kind,
        PolicyGraphNodeKind::HumanGate { .. }
            | PolicyGraphNodeKind::ConsensusGate { .. }
            | PolicyGraphNodeKind::DryRunGate { .. }
            | PolicyGraphNodeKind::SupervisorRule { .. }
            | PolicyGraphNodeKind::Finish(_)
            | PolicyGraphNodeKind::CopyReviewPullRequestList
    )
}
