//! Generic construction primitives shared by the seeded policy graphs.
//!
//! Each helper builds one graph piece - a node, edge, group, or layout entry -
//! from string slices and wraps the identifier columns in their typed-id
//! newtypes. The seeded default graph in the parent module and the OCR/review
//! canvases in the sibling modules all build through these, so they live in
//! their own file and are re-exported from `seed` for the callers that reach
//! them as `super::node`, `super::edge`, and so on.

use super::super::{
    PORT_IN, PolicyAction, PolicyCanvasRect, PolicyGraphEdge, PolicyGraphEdgeCondition,
    PolicyGraphGroup, PolicyGraphNode, PolicyGraphNodeKind, PolicyGraphNodeLayout,
    PolicyGraphPortId,
};

pub(super) fn node(
    id: &str,
    label: &str,
    kind: PolicyGraphNodeKind,
    input_ports: &[&str],
    output_ports: &[&str],
    group_id: &str,
) -> PolicyGraphNode {
    PolicyGraphNode {
        id: id.into(),
        label: label.to_string(),
        kind,
        automation: None,
        input_ports: port_ids(input_ports),
        output_ports: port_ids(output_ports),
        group_id: Some(group_id.into()),
    }
}

pub(super) fn edge(
    id: &str,
    from_node: &str,
    from_port: &str,
    to_node: &str,
    condition: PolicyGraphEdgeCondition,
) -> PolicyGraphEdge {
    let label = edge_label(from_port, &condition);
    PolicyGraphEdge {
        id: id.into(),
        from_node: from_node.into(),
        from_port: from_port.into(),
        to_node: to_node.into(),
        to_port: PORT_IN.into(),
        label: Some(label),
        condition,
    }
}

pub(super) fn group(
    id: &str,
    label: &str,
    frame: PolicyCanvasRect,
    node_ids: Vec<&str>,
) -> PolicyGraphGroup {
    PolicyGraphGroup {
        id: id.into(),
        label: label.to_string(),
        color: None,
        frame,
        node_ids: node_ids.into_iter().map(Into::into).collect(),
    }
}

pub(super) fn rect(x: i32, y: i32, width: i32, height: i32) -> PolicyCanvasRect {
    PolicyCanvasRect {
        x,
        y,
        width,
        height,
    }
}

pub(super) fn layout(node_id: &str, x: i32, y: i32) -> PolicyGraphNodeLayout {
    PolicyGraphNodeLayout {
        node_id: node_id.into(),
        x,
        y,
        source: None,
    }
}

pub(super) fn action_in(actions: Vec<PolicyAction>) -> PolicyGraphEdgeCondition {
    PolicyGraphEdgeCondition::ActionIn { actions }
}

pub(super) fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(ToString::to_string).collect()
}

fn port_ids(values: &[&str]) -> Vec<PolicyGraphPortId> {
    values
        .iter()
        .copied()
        .map(PolicyGraphPortId::from)
        .collect()
}

fn edge_label(from_port: &str, condition: &PolicyGraphEdgeCondition) -> String {
    match condition {
        PolicyGraphEdgeCondition::ActionIn { .. }
        | PolicyGraphEdgeCondition::Always
        | PolicyGraphEdgeCondition::ConditionTrue
        | PolicyGraphEdgeCondition::ConditionFalse => from_port.replace('_', " "),
        PolicyGraphEdgeCondition::EvidencePass => "checks pass".to_string(),
        PolicyGraphEdgeCondition::EvidenceFailure { reason_code } => {
            format!("fail: {reason_code:?}").to_lowercase()
        }
        PolicyGraphEdgeCondition::EvidenceConsensus { reason_code } => {
            format!("consensus: {reason_code:?}").to_lowercase()
        }
        PolicyGraphEdgeCondition::EvidenceMissing => "missing evidence".to_string(),
        PolicyGraphEdgeCondition::RiskHigh => "high risk".to_string(),
        PolicyGraphEdgeCondition::RiskLowOrEqual => "low risk".to_string(),
        PolicyGraphEdgeCondition::RiskMissing => "missing risk".to_string(),
    }
}
