use super::{
    DEFAULT_AUTO_MERGE_RISK_THRESHOLD, POLICY_GRAPH_INITIAL_REVISION, POLICY_GRAPH_SCHEMA_VERSION,
    PORT_CONSENSUS, PORT_DEFAULT, PORT_FAIL, PORT_HIGH, PORT_IN, PORT_LOW_OR_EQUAL, PORT_MERGE,
    PORT_MISSING, PORT_MUTATE, PORT_PASS, PORT_UNSAFE, PolicyAction, PolicyActionStep,
    PolicyCanvasRect, PolicyDecision, PolicyEvidenceCheck, PolicyEvidenceField,
    PolicyEvidencePredicate, PolicyGraph, PolicyGraphAutomationBinding, PolicyGraphDecision,
    PolicyGraphEdge, PolicyGraphEdgeCondition, PolicyGraphGroup, PolicyGraphLayout,
    PolicyGraphMode, PolicyGraphNode, PolicyGraphNodeKind, PolicyGraphNodeLayout, PolicyReasonCode,
    UNSAFE_HIGH_RISK_ACTIONS,
};

mod review_text_paste;

pub(crate) use review_text_paste::{
    legacy_composed_review_text_paste_dry_run_document, review_text_paste_dry_run_document,
};

pub(super) fn seeded_nodes() -> Vec<PolicyGraphNode> {
    vec![
        node(
            "action:router",
            "Action gate",
            action_kind(),
            &[PORT_IN],
            &[PORT_DEFAULT, PORT_MUTATE, PORT_MERGE, PORT_UNSAFE],
            "entry",
        ),
        supervisor(
            "supervisor:default-allow",
            PolicyGraphDecision::Allow,
            vec![PolicyReasonCode::DefaultAllow],
        ),
        dry_run("dry_run:mutate_repo", PolicyReasonCode::DryRunRequired),
        human("human:unsafe-action", PolicyReasonCode::HumanRequired),
        node(
            "evidence:merge",
            "Merge evidence",
            evidence_kind(),
            &[PORT_IN],
            &[PORT_PASS, PORT_FAIL, PORT_CONSENSUS, PORT_MISSING],
            "merge",
        ),
        node(
            "risk:merge",
            "Merge risk",
            risk_kind(),
            &[PORT_IN],
            &[PORT_LOW_OR_EQUAL, PORT_HIGH, PORT_MISSING],
            "merge",
        ),
        human(
            "human:missing-merge-evidence",
            PolicyReasonCode::MissingMergeEvidence,
        ),
        consensus(
            "consensus:protected-path",
            PolicyReasonCode::ProtectedPathTouched,
        ),
        dry_run(
            "dry_run:high-risk-merge",
            PolicyReasonCode::RiskAboveThreshold,
        ),
        supervisor(
            "supervisor:merge-deny",
            PolicyGraphDecision::Deny,
            merge_deny_reasons(),
        ),
        supervisor(
            "supervisor:auto-merge",
            PolicyGraphDecision::Allow,
            vec![PolicyReasonCode::AutoMergeAllowed],
        ),
    ]
}

pub(super) fn seeded_edges() -> Vec<PolicyGraphEdge> {
    let mut edges = vec![
        edge(
            "edge:default",
            "action:router",
            PORT_DEFAULT,
            "supervisor:default-allow",
            action_in(default_allow_actions()),
        ),
        edge(
            "edge:mutate",
            "action:router",
            PORT_MUTATE,
            "dry_run:mutate_repo",
            action_in(vec![PolicyAction::MutateRepo]),
        ),
        edge(
            "edge:unsafe",
            "action:router",
            PORT_UNSAFE,
            "human:unsafe-action",
            action_in(UNSAFE_HIGH_RISK_ACTIONS.to_vec()),
        ),
        edge(
            "edge:merge",
            "action:router",
            PORT_MERGE,
            "evidence:merge",
            action_in(vec![PolicyAction::MergePr]),
        ),
        edge(
            "edge:evidence-pass",
            "evidence:merge",
            PORT_PASS,
            "risk:merge",
            PolicyGraphEdgeCondition::EvidencePass,
        ),
        edge(
            "edge:evidence-consensus",
            "evidence:merge",
            PORT_CONSENSUS,
            "consensus:protected-path",
            PolicyGraphEdgeCondition::EvidenceConsensus {
                reason_code: PolicyReasonCode::ProtectedPathTouched,
            },
        ),
        edge(
            "edge:evidence-missing",
            "evidence:merge",
            PORT_MISSING,
            "human:missing-merge-evidence",
            PolicyGraphEdgeCondition::EvidenceMissing,
        ),
        edge(
            "edge:risk-low",
            "risk:merge",
            PORT_LOW_OR_EQUAL,
            "supervisor:auto-merge",
            PolicyGraphEdgeCondition::RiskLowOrEqual,
        ),
        edge(
            "edge:risk-high",
            "risk:merge",
            PORT_HIGH,
            "dry_run:high-risk-merge",
            PolicyGraphEdgeCondition::RiskHigh,
        ),
        edge(
            "edge:risk-missing",
            "risk:merge",
            PORT_MISSING,
            "human:missing-merge-evidence",
            PolicyGraphEdgeCondition::RiskMissing,
        ),
    ];
    edges.extend(merge_deny_reasons().into_iter().map(|reason_code| {
        let id = format!("edge:evidence-fail:{reason_code:?}");
        edge(
            &id,
            "evidence:merge",
            PORT_FAIL,
            "supervisor:merge-deny",
            PolicyGraphEdgeCondition::EvidenceFailure { reason_code },
        )
    }));
    edges
}

pub(super) fn seeded_groups() -> Vec<PolicyGraphGroup> {
    vec![
        group(
            "entry",
            "Action routing",
            rect(36, 72, 256, 200),
            vec!["action:router"],
        ),
        group(
            "merge",
            "Merge checks",
            rect(316, 72, 256, 380),
            vec!["evidence:merge", "risk:merge"],
        ),
        group(
            "terminal",
            "Terminal decisions",
            rect(676, 72, 476, 620),
            vec![
                "supervisor:default-allow",
                "dry_run:mutate_repo",
                "human:unsafe-action",
                "human:missing-merge-evidence",
                "consensus:protected-path",
                "dry_run:high-risk-merge",
                "supervisor:merge-deny",
                "supervisor:auto-merge",
            ],
        ),
    ]
}

pub(super) fn layout_for(nodes: &[PolicyGraphNode]) -> PolicyGraphLayout {
    PolicyGraphLayout {
        nodes: nodes
            .iter()
            .enumerate()
            .map(|(index, node)| PolicyGraphNodeLayout {
                node_id: node.id.clone(),
                x: layout_position(&node.id, index).0,
                y: layout_position(&node.id, index).1,
            })
            .collect(),
    }
}

pub(super) fn trace_for(
    graph: &PolicyGraph,
    input: &super::PolicyInput,
    decision: &PolicyDecision,
) -> Vec<String> {
    seeded_trace_for(input, decision)
        .into_iter()
        .filter(|id| graph.nodes.iter().any(|node| node.id == *id))
        .map(str::to_string)
        .collect()
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
        id: id.to_string(),
        from_node: from_node.to_string(),
        from_port: from_port.to_string(),
        to_node: to_node.to_string(),
        to_port: PORT_IN.to_string(),
        label: Some(label),
        condition,
    }
}

fn action_kind() -> PolicyGraphNodeKind {
    PolicyGraphNodeKind::ActionGate {
        actions: all_actions(),
    }
}

fn evidence_kind() -> PolicyGraphNodeKind {
    PolicyGraphNodeKind::EvidenceCheck {
        checks: vec![
            check(
                PolicyEvidenceField::ChecksGreen,
                PolicyEvidencePredicate::IsTrue,
                PolicyReasonCode::ChecksNotGreen,
            ),
            check(
                PolicyEvidenceField::BranchProtectionAllowsMerge,
                PolicyEvidencePredicate::IsTrue,
                PolicyReasonCode::BranchProtectionBlocked,
            ),
            check(
                PolicyEvidenceField::ReviewerVerdictApproved,
                PolicyEvidencePredicate::IsTrue,
                PolicyReasonCode::ReviewerNotApproved,
            ),
            check(
                PolicyEvidenceField::UnresolvedRequestedChanges,
                PolicyEvidencePredicate::IsZero,
                PolicyReasonCode::UnresolvedRequestedChanges,
            ),
            check(
                PolicyEvidenceField::ProtectedPathTouched,
                PolicyEvidencePredicate::IsFalse,
                PolicyReasonCode::ProtectedPathTouched,
            ),
        ],
    }
}

fn risk_kind() -> PolicyGraphNodeKind {
    PolicyGraphNodeKind::RiskClassifier {
        field: PolicyEvidenceField::RiskScore,
        threshold: DEFAULT_AUTO_MERGE_RISK_THRESHOLD,
        high_risk_reason_code: PolicyReasonCode::RiskAboveThreshold,
        missing_reason_code: PolicyReasonCode::MissingMergeEvidence,
    }
}

fn check(
    field: PolicyEvidenceField,
    pass: PolicyEvidencePredicate,
    fail_reason_code: PolicyReasonCode,
) -> PolicyEvidenceCheck {
    PolicyEvidenceCheck {
        field,
        pass,
        fail_reason_code,
        missing_reason_code: PolicyReasonCode::MissingMergeEvidence,
    }
}

fn node(
    id: &str,
    label: &str,
    kind: PolicyGraphNodeKind,
    input_ports: &[&str],
    output_ports: &[&str],
    group_id: &str,
) -> PolicyGraphNode {
    PolicyGraphNode {
        id: id.to_string(),
        label: label.to_string(),
        kind,
        automation: None,
        input_ports: strings(input_ports),
        output_ports: strings(output_ports),
        group_id: Some(group_id.to_string()),
    }
}

fn supervisor(
    id: &str,
    decision: PolicyGraphDecision,
    reason_codes: Vec<PolicyReasonCode>,
) -> PolicyGraphNode {
    node(
        id,
        id,
        PolicyGraphNodeKind::SupervisorRule {
            decision,
            reason_codes,
        },
        &[PORT_IN],
        &[],
        "terminal",
    )
}

fn human(id: &str, reason_code: PolicyReasonCode) -> PolicyGraphNode {
    node(
        id,
        id,
        PolicyGraphNodeKind::HumanGate { reason_code },
        &[PORT_IN],
        &[],
        "terminal",
    )
}

fn consensus(id: &str, reason_code: PolicyReasonCode) -> PolicyGraphNode {
    node(
        id,
        id,
        PolicyGraphNodeKind::ConsensusGate { reason_code },
        &[PORT_IN],
        &[],
        "terminal",
    )
}

fn dry_run(id: &str, reason_code: PolicyReasonCode) -> PolicyGraphNode {
    node(
        id,
        id,
        PolicyGraphNodeKind::DryRunGate { reason_code },
        &[PORT_IN],
        &[],
        "terminal",
    )
}

fn group(id: &str, label: &str, frame: PolicyCanvasRect, node_ids: Vec<&str>) -> PolicyGraphGroup {
    PolicyGraphGroup {
        id: id.to_string(),
        label: label.to_string(),
        color: None,
        frame,
        node_ids: node_ids.into_iter().map(str::to_string).collect(),
    }
}

fn rect(x: i32, y: i32, width: i32, height: i32) -> PolicyCanvasRect {
    PolicyCanvasRect {
        x,
        y,
        width,
        height,
    }
}

fn layout(node_id: &str, x: i32, y: i32) -> PolicyGraphNodeLayout {
    PolicyGraphNodeLayout {
        node_id: node_id.to_string(),
        x,
        y,
    }
}

fn edge_label(from_port: &str, condition: &PolicyGraphEdgeCondition) -> String {
    match condition {
        PolicyGraphEdgeCondition::ActionIn { .. }
        | PolicyGraphEdgeCondition::Always
        | PolicyGraphEdgeCondition::ConditionTrue
        | PolicyGraphEdgeCondition::ConditionFalse => {
            from_port.replace('_', " ")
        }
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

fn layout_position(node_id: &str, fallback_index: usize) -> (i32, i32) {
    match node_id {
        "action:router" => (80, 124),
        "evidence:merge" => (360, 124),
        "risk:merge" => (360, 304),
        "supervisor:default-allow" => (720, 124),
        "dry_run:mutate_repo" => (940, 124),
        "human:unsafe-action" => (720, 264),
        "human:missing-merge-evidence" => (940, 264),
        "consensus:protected-path" => (720, 404),
        "dry_run:high-risk-merge" => (940, 404),
        "supervisor:merge-deny" => (720, 544),
        "supervisor:auto-merge" => (940, 544),
        _ => {
            let column = i32::try_from(fallback_index % 4).unwrap_or_default();
            let row = i32::try_from(fallback_index / 4).unwrap_or_default();
            (60 + column * 220, 120 + row * 140)
        }
    }
}

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(ToString::to_string).collect()
}

fn action_in(actions: Vec<PolicyAction>) -> PolicyGraphEdgeCondition {
    PolicyGraphEdgeCondition::ActionIn { actions }
}

fn merge_deny_reasons() -> Vec<PolicyReasonCode> {
    vec![
        PolicyReasonCode::ChecksNotGreen,
        PolicyReasonCode::BranchProtectionBlocked,
        PolicyReasonCode::ReviewerNotApproved,
        PolicyReasonCode::UnresolvedRequestedChanges,
    ]
}

fn default_allow_actions() -> Vec<PolicyAction> {
    vec![
        PolicyAction::Sync,
        PolicyAction::Triage,
        PolicyAction::Plan,
        PolicyAction::SpawnAgent,
        PolicyAction::PushBranch,
        PolicyAction::OpenPr,
        PolicyAction::SubmitReview,
        PolicyAction::StopAgent,
    ]
}

fn all_actions() -> Vec<PolicyAction> {
    let mut actions = default_allow_actions();
    actions.extend([
        PolicyAction::MutateRepo,
        PolicyAction::MergePr,
        PolicyAction::DeleteWorktree,
        PolicyAction::AccessSecret,
        PolicyAction::DestructiveFs,
    ]);
    actions
}

fn seeded_trace_for(input: &super::PolicyInput, decision: &PolicyDecision) -> Vec<&'static str> {
    match input.action {
        PolicyAction::MergePr => merge_trace_for(decision),
        PolicyAction::MutateRepo => vec!["action:router", "dry_run:mutate_repo"],
        PolicyAction::DeleteWorktree | PolicyAction::AccessSecret | PolicyAction::DestructiveFs => {
            vec!["action:router", "human:unsafe-action"]
        }
        _ => vec!["action:router", "supervisor:default-allow"],
    }
}

fn merge_trace_for(decision: &PolicyDecision) -> Vec<&'static str> {
    let mut trace = vec!["action:router", "evidence:merge"];
    match decision_reason(decision) {
        PolicyReasonCode::MissingMergeEvidence => trace.push("human:missing-merge-evidence"),
        PolicyReasonCode::ProtectedPathTouched => trace.push("consensus:protected-path"),
        PolicyReasonCode::RiskAboveThreshold => {
            trace.extend(["risk:merge", "dry_run:high-risk-merge"]);
        }
        PolicyReasonCode::AutoMergeAllowed => trace.extend(["risk:merge", "supervisor:auto-merge"]),
        _ => trace.push("supervisor:merge-deny"),
    }
    trace
}

fn decision_reason(decision: &PolicyDecision) -> PolicyReasonCode {
    match decision {
        PolicyDecision::Allow { reason_code, .. }
        | PolicyDecision::Deny { reason_code, .. }
        | PolicyDecision::RequireHuman { reason_code, .. }
        | PolicyDecision::RequireConsensus { reason_code, .. }
        | PolicyDecision::DryRunOnly { reason_code, .. } => *reason_code,
    }
}
