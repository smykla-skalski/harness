@testable import HarnessMonitorKit
import HarnessMonitorPolicyModels

func policyDocument(revision: UInt64) -> PolicyPipelineDocument {
  PolicyPipelineDocument(
    schemaVersion: 2,
    revision: revision,
    mode: .draft,
    nodes: [
      PolicyPipelineNode(
        id: "node-intake",
        title: "Ready for dispatch",
        kind: .actionGate(actions: [.spawnAgent]),
        groupId: "group-dispatch",
        inputs: [PolicyPipelinePort(id: "in", title: "in")],
        outputs: [PolicyPipelinePort(id: "default", title: "default")]
      ),
      PolicyPipelineNode(
        id: "stuck-agent",
        title: "Stuck agent rule",
        kind: .supervisorRule(decision: .allow, reasonCodes: [.defaultAllow]),
        groupId: "group-dispatch",
        inputs: [PolicyPipelinePort(id: "in", title: "in")]
      ),
    ],
    edges: [
      PolicyPipelineEdge(
        id: "edge-intake-supervisor",
        fromNodeId: "node-intake",
        fromPort: "default",
        toNodeId: "stuck-agent",
        toPort: "in"
      )
    ],
    groups: [
      PolicyPipelineGroup(
        id: "group-dispatch",
        title: "Dispatch",
        nodeIds: ["node-intake", "stuck-agent"]
      )
    ],
    layout: PolicyPipelineLayout(
      nodes: [
        PolicyPipelineNodeLayout(nodeId: "node-intake", x: 20, y: 40),
        PolicyPipelineNodeLayout(nodeId: "stuck-agent", x: 280, y: 40),
      ]
    ),
    policyTraceIds: ["trace-policy-11"]
  )
}

func richPolicyDocument(revision: UInt64) -> PolicyPipelineDocument {
  PolicyPipelineDocument(
    schemaVersion: 2,
    revision: revision,
    mode: .draft,
    nodes: [
      PolicyPipelineNode(
        id: "node-evidence",
        title: "Check evidence",
        kind: .evidenceCheck(checks: [
          PolicyEvidenceCheck(
            field: .checksGreen,
            pass: .isTrue,
            failReasonCode: .checksNotGreen,
            missingReasonCode: .missingMergeEvidence
          )
        ]),
        groupId: "group-rich",
        inputs: [PolicyPipelinePort(id: "input-event", title: "event")],
        outputs: [
          PolicyPipelinePort(id: "output-pass", title: "pass"),
          PolicyPipelinePort(id: "output-fail", title: "fail"),
        ]
      ),
      PolicyPipelineNode(
        id: "node-risk",
        title: "Risk score",
        kind: .riskClassifier(field: .riskScore, threshold: 74, highRiskReasonCode: .riskAboveThreshold, missingReasonCode: .humanRequired),
        groupId: "group-rich",
        inputs: [PolicyPipelinePort(id: "input-event", title: "event")],
        outputs: [
          PolicyPipelinePort(id: "output-high", title: "high"),
          PolicyPipelinePort(id: "output-low", title: "low"),
        ]
      ),
    ],
    edges: [
      PolicyPipelineEdge(
        id: "edge-evidence-risk-fail",
        fromNodeId: "node-evidence",
        fromPort: "output-fail",
        toNodeId: "node-risk",
        toPort: "input-event",
        condition: PolicyPipelineEdgeCondition(
          condition: "evidence_failure",
          reasonCode: "checks_not_green"
        )
      )
    ],
    groups: [
      PolicyPipelineGroup(
        id: "group-rich",
        title: "Rich policy",
        nodeIds: ["node-evidence", "node-risk"]
      )
    ],
    layout: PolicyPipelineLayout(
      nodes: [
        PolicyPipelineNodeLayout(nodeId: "node-evidence", x: 20, y: 40),
        PolicyPipelineNodeLayout(nodeId: "node-risk", x: 300, y: 40),
      ]
    ),
    policyTraceIds: ["trace-rich-policy"]
  )
}

func overlappingDefaultPolicyDocument(
  revision: UInt64
) -> PolicyPipelineDocument {
  let nodes = defaultPolicyNodeSpecs.map { spec in
    PolicyPipelineNode(
      id: PolicyGraphNodeId(spec.id),
      title: spec.title,
      kind: spec.kind,
      groupId: PolicyGraphGroupId(spec.groupID),
      inputs: [PolicyPipelinePort(id: "in", title: "in")],
      outputs: spec.outputs.map { PolicyPipelinePort(id: PolicyGraphPortId($0), title: $0) }
    )
  }
  return PolicyPipelineDocument(
    schemaVersion: 2,
    revision: revision,
    mode: .draft,
    nodes: nodes,
    edges: [],
    groups: [
      PolicyPipelineGroup(
        id: "entry",
        title: "Action routing",
        nodeIds: ["action:router"]
      ),
      PolicyPipelineGroup(
        id: "merge",
        title: "Merge checks",
        nodeIds: ["evidence:merge", "risk:merge"]
      ),
      PolicyPipelineGroup(
        id: "terminal",
        title: "Terminal decisions",
        nodeIds: defaultPolicyNodeSpecs.filter { $0.groupID == "terminal" }.map { PolicyGraphNodeId($0.id) }
      ),
    ],
    layout: PolicyPipelineLayout(
      nodes: nodes.enumerated().map { index, node in
        PolicyPipelineNodeLayout(
          nodeId: node.id,
          x: (index % 4) * 260,
          y: (index / 4) * 140
        )
      }
    ),
    policyTraceIds: ["trace-default-policy"]
  )
}

/// Mirror of the daemon's seeded policy graph (`src/task_board/policy_graph/seed.rs`):
/// the same nodes, edges, explicit non-overlapping group frames, and hand-tuned
/// layout coordinates the live Dashboard>Policies canvas receives for a fresh
/// policy. Unlike `overlappingDefaultPolicyDocument`, these coordinates are
/// already tidy, so loading them keeps the saved arrangement instead of
/// auto-arranging - exactly the state a user sees before pressing Reformat.
func seededDefaultPolicyDocument(revision: UInt64) -> PolicyPipelineDocument {
  let nodes = defaultPolicyNodeSpecs.map { spec in
    PolicyPipelineNode(
      id: PolicyGraphNodeId(spec.id),
      title: spec.title,
      kind: spec.kind,
      groupId: PolicyGraphGroupId(spec.groupID),
      inputs: [PolicyPipelinePort(id: "in", title: "in")],
      outputs: spec.outputs.map { PolicyPipelinePort(id: PolicyGraphPortId($0), title: $0) }
    )
  }
  return PolicyPipelineDocument(
    schemaVersion: 2,
    revision: revision,
    mode: .draft,
    nodes: nodes,
    edges: seededDefaultPolicyEdges,
    groups: [
      PolicyPipelineGroup(
        id: "entry",
        title: "Action routing",
        frame: PolicyCanvasRect(x: 36, y: 72, width: 256, height: 200),
        nodeIds: ["action:router"]
      ),
      PolicyPipelineGroup(
        id: "merge",
        title: "Merge checks",
        frame: PolicyCanvasRect(x: 316, y: 72, width: 256, height: 380),
        nodeIds: ["evidence:merge", "risk:merge"]
      ),
      PolicyPipelineGroup(
        id: "terminal",
        title: "Terminal decisions",
        frame: PolicyCanvasRect(x: 676, y: 72, width: 476, height: 620),
        nodeIds: defaultPolicyNodeSpecs.filter { $0.groupID == "terminal" }.map { PolicyGraphNodeId($0.id) }
      ),
    ],
    layout: PolicyPipelineLayout(
      nodes: nodes.map { node in
        let position = seededDefaultPolicyPositions[node.id.rawValue] ?? (0, 0)
        return PolicyPipelineNodeLayout(nodeId: node.id, x: position.0, y: position.1)
      }
    ),
    policyTraceIds: ["trace-seeded-policy-\(revision)"]
  )
}

/// The exact saved layout the live Dashboard>Policies canvas renders for the
/// default policy - captured verbatim from the daemon's database-backed active
/// "Default" canvas (mode=draft, revision 63).
/// Unlike `seededDefaultPolicyDocument`, these are the user-arranged coordinates
/// (not the seed's hand-tuned origin), so loading them reproduces precisely what
/// the canvas shows - no reflow, no nudge. Same topology: the four
/// `evidence:merge:fail -> supervisor:merge-deny:in` edges fan in from one source
/// port to one target port. Faithful to the live database row, those four edges carry
/// `condition: "evidence_failure"` with a distinct `reason_code` each and the
/// shared `"evidence failure"` label, so loading reproduces the red dashed
/// error styling and gives the merge fold real reason codes to read.
func liveSavedDefaultPolicyDocument(revision: UInt64) -> PolicyPipelineDocument {
  let nodes = defaultPolicyNodeSpecs.map { spec in
    PolicyPipelineNode(
      id: PolicyGraphNodeId(spec.id),
      title: spec.title,
      kind: spec.kind,
      groupId: PolicyGraphGroupId(spec.groupID),
      inputs: [PolicyPipelinePort(id: "in", title: "in")],
      outputs: spec.outputs.map { PolicyPipelinePort(id: PolicyGraphPortId($0), title: $0) }
    )
  }
  return PolicyPipelineDocument(
    schemaVersion: 2,
    revision: revision,
    mode: .draft,
    nodes: nodes,
    edges: liveSavedDefaultPolicyEdges,
    groups: [
      PolicyPipelineGroup(
        id: "entry",
        title: "Action routing",
        frame: PolicyCanvasRect(x: 1200, y: 1920, width: 256, height: 200),
        nodeIds: ["action:router"]
      ),
      PolicyPipelineGroup(
        id: "merge",
        title: "Merge checks",
        frame: PolicyCanvasRect(x: 1580, y: 1200, width: 556, height: 200),
        nodeIds: ["evidence:merge", "risk:merge"]
      ),
      PolicyPipelineGroup(
        id: "terminal",
        title: "Terminal decisions",
        frame: PolicyCanvasRect(x: 2260, y: 1560, width: 556, height: 900),
        nodeIds: defaultPolicyNodeSpecs.filter { $0.groupID == "terminal" }.map { PolicyGraphNodeId($0.id) }
      ),
    ],
    layout: PolicyPipelineLayout(
      nodes: nodes.map { node in
        let position = liveSavedPolicyPositions[node.id.rawValue] ?? (0, 0)
        return PolicyPipelineNodeLayout(nodeId: node.id, x: position.0, y: position.1)
      }
    ),
    policyTraceIds: ["trace-live-saved-\(revision)"]
  )
}

/// The seeded edge set with the four `evidence:merge:fail -> supervisor:merge-deny`
/// edges replaced by the live database row's faithful shape: shared `"evidence failure"`
/// label, `condition: "evidence_failure"`, and a distinct daemon `reason_code` per
/// edge. The reason-code strings are the daemon snake_case contract (kept byte-equal
/// to `PolicyCanvasReasonCode`); the merge round-trip test cross-checks them.
private let liveSavedDefaultPolicyEdges: [PolicyPipelineEdge] = {
  let failReasons: [(id: String, reason: String)] = [
    ("edge:evidence-fail:checks-not-green", "checks_not_green"),
    ("edge:evidence-fail:branch-protection-blocked", "branch_protection_blocked"),
    ("edge:evidence-fail:reviewer-not-approved", "reviewer_not_approved"),
    ("edge:evidence-fail:unresolved-requested-changes", "unresolved_requested_changes"),
  ]
  let nonFailEdges = seededDefaultPolicyEdges.filter { $0.toNodeId != "supervisor:merge-deny" }
  let failEdges = failReasons.map { entry in
    PolicyPipelineEdge(
      id: PolicyGraphEdgeId(entry.id),
      fromNodeId: "evidence:merge",
      fromPort: "fail",
      toNodeId: "supervisor:merge-deny",
      toPort: "in",
      label: "evidence failure",
      condition: PolicyPipelineEdgeCondition(
        condition: "evidence_failure",
        reasonCode: entry.reason
      )
    )
  }
  return nonFailEdges + failEdges
}()

private let liveSavedPolicyPositions: [String: (Int, Int)] = [
  "action:router": (1244, 1972),
  "evidence:merge": (1624, 1252),
  "risk:merge": (1924, 1252),
  "supervisor:default-allow": (2604, 2072),
  "dry_run:mutate_repo": (2304, 2312),
  "human:unsafe-action": (2604, 2312),
  "human:missing-merge-evidence": (2304, 1832),
  "consensus:protected-path": (2604, 1832),
  "dry_run:high-risk-merge": (2304, 1612),
  "supervisor:merge-deny": (2304, 2072),
  "supervisor:auto-merge": (2604, 1612),
]

private let seededDefaultPolicyPositions: [String: (Int, Int)] = [
  "action:router": (80, 124),
  "evidence:merge": (360, 124),
  "risk:merge": (360, 304),
  "supervisor:default-allow": (720, 124),
  "dry_run:mutate_repo": (940, 124),
  "human:unsafe-action": (720, 264),
  "human:missing-merge-evidence": (940, 264),
  "consensus:protected-path": (720, 404),
  "dry_run:high-risk-merge": (940, 404),
  "supervisor:merge-deny": (720, 544),
  "supervisor:auto-merge": (940, 544),
]

private let seededDefaultPolicyEdges: [PolicyPipelineEdge] = {
  var edges = [
    seededEdge("edge:default", "action:router", "default", "supervisor:default-allow"),
    seededEdge("edge:mutate", "action:router", "mutate", "dry_run:mutate_repo"),
    seededEdge("edge:unsafe", "action:router", "unsafe", "human:unsafe-action"),
    seededEdge("edge:merge", "action:router", "merge", "evidence:merge"),
    seededEdge("edge:evidence-pass", "evidence:merge", "pass", "risk:merge"),
    seededEdge(
      "edge:evidence-consensus", "evidence:merge", "consensus", "consensus:protected-path"),
    seededEdge(
      "edge:evidence-missing", "evidence:merge", "missing", "human:missing-merge-evidence"),
    seededEdge("edge:risk-low", "risk:merge", "low_or_equal", "supervisor:auto-merge"),
    seededEdge("edge:risk-high", "risk:merge", "high", "dry_run:high-risk-merge"),
    seededEdge("edge:risk-missing", "risk:merge", "missing", "human:missing-merge-evidence"),
  ]
  for reason in ["checks-not-green", "branch-protection", "reviewer", "unresolved"] {
    edges.append(
      seededEdge(
        "edge:evidence-fail:\(reason)",
        "evidence:merge",
        "fail",
        "supervisor:merge-deny"
      )
    )
  }
  return edges
}()

private func seededEdge(
  _ id: String,
  _ fromNode: String,
  _ fromPort: String,
  _ toNode: String
) -> PolicyPipelineEdge {
  PolicyPipelineEdge(
    id: PolicyGraphEdgeId(id),
    fromNodeId: PolicyGraphNodeId(fromNode),
    fromPort: PolicyGraphPortId(fromPort),
    toNodeId: PolicyGraphNodeId(toNode),
    toPort: "in"
  )
}

private struct DefaultPolicyNodeSpec {
  let id: String
  let title: String
  let kind: PolicyGraphNodeKind
  let groupID: String
  let outputs: [String]
}

private let defaultPolicyNodeSpecs: [DefaultPolicyNodeSpec] = [
  DefaultPolicyNodeSpec(
    id: "action:router",
    title: "Action gate",
    kind: .actionGate(actions: [.spawnAgent]),
    groupID: "entry",
    outputs: ["default", "mutate", "merge", "unsafe"]
  ),
  DefaultPolicyNodeSpec(
    id: "evidence:merge",
    title: "Merge evidence",
    kind: .evidenceCheck(checks: []),
    groupID: "merge",
    outputs: ["pass", "fail", "consensus", "missing"]
  ),
  DefaultPolicyNodeSpec(
    id: "risk:merge",
    title: "Merge risk",
    kind: .riskClassifier(field: .riskScore, threshold: 0, highRiskReasonCode: .riskAboveThreshold, missingReasonCode: .humanRequired),
    groupID: "merge",
    outputs: ["low_or_equal", "high", "missing"]
  ),
  DefaultPolicyNodeSpec(
    id: "supervisor:default-allow",
    title: "supervisor:default-allow",
    kind: .supervisorRule(decision: .allow, reasonCodes: [.defaultAllow]),
    groupID: "terminal",
    outputs: []
  ),
  DefaultPolicyNodeSpec(
    id: "dry_run:mutate_repo",
    title: "dry_run:mutate_repo",
    kind: .dryRunGate(reasonCode: .dryRunRequired),
    groupID: "terminal",
    outputs: []
  ),
  DefaultPolicyNodeSpec(
    id: "human:unsafe-action",
    title: "human:unsafe-action",
    kind: .humanGate(reasonCode: .humanRequired),
    groupID: "terminal",
    outputs: []
  ),
  DefaultPolicyNodeSpec(
    id: "human:missing-merge-evidence",
    title: "human:missing-merge-evidence",
    kind: .humanGate(reasonCode: .humanRequired),
    groupID: "terminal",
    outputs: []
  ),
  DefaultPolicyNodeSpec(
    id: "consensus:protected-path",
    title: "consensus:protected-path",
    kind: .consensusGate(reasonCode: .protectedPathTouched),
    groupID: "terminal",
    outputs: []
  ),
  DefaultPolicyNodeSpec(
    id: "dry_run:high-risk-merge",
    title: "dry_run:high-risk-merge",
    kind: .dryRunGate(reasonCode: .dryRunRequired),
    groupID: "terminal",
    outputs: []
  ),
  DefaultPolicyNodeSpec(
    id: "supervisor:merge-deny",
    title: "supervisor:merge-deny",
    kind: .supervisorRule(decision: .deny, reasonCodes: [.checksNotGreen]),
    groupID: "terminal",
    outputs: []
  ),
  DefaultPolicyNodeSpec(
    id: "supervisor:auto-merge",
    title: "supervisor:auto-merge",
    kind: .supervisorRule(decision: .allow, reasonCodes: [.autoMergeAllowed]),
    groupID: "terminal",
    outputs: []
  ),
]
