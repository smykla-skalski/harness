@testable import HarnessMonitorKit

func policyDocument(revision: UInt64) -> TaskBoardPolicyPipelineDocument {
  TaskBoardPolicyPipelineDocument(
    schemaVersion: 2,
    revision: revision,
    mode: .draft,
    nodes: [
      TaskBoardPolicyPipelineNode(
        id: "node-intake",
        title: "Ready for dispatch",
        kind: TaskBoardPolicyPipelineNodeKind(kind: "action_gate", actions: [.spawnAgent]),
        groupId: "group-dispatch",
        inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
        outputs: [TaskBoardPolicyPipelinePort(id: "default", title: "default")]
      ),
      TaskBoardPolicyPipelineNode(
        id: "node-supervisor",
        title: "Stuck agent rule",
        kind: TaskBoardPolicyPipelineNodeKind(
          kind: "supervisor_rule",
          ruleId: "stuck-agent",
          reasonCodes: ["default_allow"],
          decision: "allow"
        ),
        groupId: "group-dispatch",
        inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")]
      ),
    ],
    edges: [
      TaskBoardPolicyPipelineEdge(
        id: "edge-intake-supervisor",
        fromNodeId: "node-intake",
        fromPort: "default",
        toNodeId: "node-supervisor",
        toPort: "in"
      )
    ],
    groups: [
      TaskBoardPolicyPipelineGroup(
        id: "group-dispatch",
        title: "Dispatch",
        nodeIds: ["node-intake", "node-supervisor"]
      )
    ],
    layout: TaskBoardPolicyPipelineLayout(
      nodes: [
        TaskBoardPolicyPipelineNodeLayout(nodeId: "node-intake", x: 20, y: 40),
        TaskBoardPolicyPipelineNodeLayout(nodeId: "node-supervisor", x: 280, y: 40),
      ]
    ),
    policyTraceIds: ["trace-policy-11"]
  )
}

func richPolicyDocument(revision: UInt64) -> TaskBoardPolicyPipelineDocument {
  TaskBoardPolicyPipelineDocument(
    schemaVersion: 2,
    revision: revision,
    mode: .draft,
    nodes: [
      TaskBoardPolicyPipelineNode(
        id: "node-evidence",
        title: "Check evidence",
        kind: TaskBoardPolicyPipelineNodeKind(
          kind: "evidence_check",
          checks: [
            TaskBoardPolicyEvidenceCheck(
              field: .checksGreen,
              pass: TaskBoardPolicyEvidencePredicate(predicate: .isTrue),
              failReasonCode: "checks_not_green",
              missingReasonCode: "checks_missing"
            )
          ]
        ),
        groupId: "group-rich",
        inputs: [TaskBoardPolicyPipelinePort(id: "input-event", title: "event")],
        outputs: [
          TaskBoardPolicyPipelinePort(id: "output-pass", title: "pass"),
          TaskBoardPolicyPipelinePort(id: "output-fail", title: "fail"),
        ]
      ),
      TaskBoardPolicyPipelineNode(
        id: "node-risk",
        title: "Risk score",
        kind: TaskBoardPolicyPipelineNodeKind(
          kind: "risk_classifier",
          field: .riskScore,
          threshold: 74,
          highRiskReasonCode: "merge_risk_high",
          missingReasonCode: "merge_risk_missing"
        ),
        groupId: "group-rich",
        inputs: [TaskBoardPolicyPipelinePort(id: "input-event", title: "event")],
        outputs: [
          TaskBoardPolicyPipelinePort(id: "output-high", title: "high"),
          TaskBoardPolicyPipelinePort(id: "output-low", title: "low"),
        ]
      ),
    ],
    edges: [
      TaskBoardPolicyPipelineEdge(
        id: "edge-evidence-risk-fail",
        fromNodeId: "node-evidence",
        fromPort: "output-fail",
        toNodeId: "node-risk",
        toPort: "input-event",
        condition: TaskBoardPolicyPipelineEdgeCondition(
          condition: "evidence_failure",
          reasonCode: "checks_not_green"
        )
      )
    ],
    groups: [
      TaskBoardPolicyPipelineGroup(
        id: "group-rich",
        title: "Rich policy",
        nodeIds: ["node-evidence", "node-risk"]
      )
    ],
    layout: TaskBoardPolicyPipelineLayout(
      nodes: [
        TaskBoardPolicyPipelineNodeLayout(nodeId: "node-evidence", x: 20, y: 40),
        TaskBoardPolicyPipelineNodeLayout(nodeId: "node-risk", x: 300, y: 40),
      ]
    ),
    policyTraceIds: ["trace-rich-policy"]
  )
}

func overlappingDefaultPolicyDocument(
  revision: UInt64
) -> TaskBoardPolicyPipelineDocument {
  let nodes = defaultPolicyNodeSpecs.map { spec in
    TaskBoardPolicyPipelineNode(
      id: spec.id,
      title: spec.title,
      kind: spec.kind,
      groupId: spec.groupID,
      inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
      outputs: spec.outputs.map { TaskBoardPolicyPipelinePort(id: $0, title: $0) }
    )
  }
  return TaskBoardPolicyPipelineDocument(
    schemaVersion: 2,
    revision: revision,
    mode: .draft,
    nodes: nodes,
    edges: [],
    groups: [
      TaskBoardPolicyPipelineGroup(
        id: "entry",
        title: "Action routing",
        nodeIds: ["action:router"]
      ),
      TaskBoardPolicyPipelineGroup(
        id: "merge",
        title: "Merge checks",
        nodeIds: ["evidence:merge", "risk:merge"]
      ),
      TaskBoardPolicyPipelineGroup(
        id: "terminal",
        title: "Terminal decisions",
        nodeIds: defaultPolicyNodeSpecs.filter { $0.groupID == "terminal" }.map(\.id)
      ),
    ],
    layout: TaskBoardPolicyPipelineLayout(
      nodes: nodes.enumerated().map { index, node in
        TaskBoardPolicyPipelineNodeLayout(
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
func seededDefaultPolicyDocument(revision: UInt64) -> TaskBoardPolicyPipelineDocument {
  let nodes = defaultPolicyNodeSpecs.map { spec in
    TaskBoardPolicyPipelineNode(
      id: spec.id,
      title: spec.title,
      kind: spec.kind,
      groupId: spec.groupID,
      inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
      outputs: spec.outputs.map { TaskBoardPolicyPipelinePort(id: $0, title: $0) }
    )
  }
  return TaskBoardPolicyPipelineDocument(
    schemaVersion: 2,
    revision: revision,
    mode: .draft,
    nodes: nodes,
    edges: seededDefaultPolicyEdges,
    groups: [
      TaskBoardPolicyPipelineGroup(
        id: "entry",
        title: "Action routing",
        frame: TaskBoardPolicyCanvasRect(x: 36, y: 72, width: 256, height: 200),
        nodeIds: ["action:router"]
      ),
      TaskBoardPolicyPipelineGroup(
        id: "merge",
        title: "Merge checks",
        frame: TaskBoardPolicyCanvasRect(x: 316, y: 72, width: 256, height: 380),
        nodeIds: ["evidence:merge", "risk:merge"]
      ),
      TaskBoardPolicyPipelineGroup(
        id: "terminal",
        title: "Terminal decisions",
        frame: TaskBoardPolicyCanvasRect(x: 676, y: 72, width: 476, height: 620),
        nodeIds: defaultPolicyNodeSpecs.filter { $0.groupID == "terminal" }.map(\.id)
      ),
    ],
    layout: TaskBoardPolicyPipelineLayout(
      nodes: nodes.map { node in
        let position = seededDefaultPolicyPositions[node.id] ?? (0, 0)
        return TaskBoardPolicyPipelineNodeLayout(nodeId: node.id, x: position.0, y: position.1)
      }
    ),
    policyTraceIds: ["trace-seeded-policy-\(revision)"]
  )
}

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

private let seededDefaultPolicyEdges: [TaskBoardPolicyPipelineEdge] = {
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
) -> TaskBoardPolicyPipelineEdge {
  TaskBoardPolicyPipelineEdge(
    id: id,
    fromNodeId: fromNode,
    fromPort: fromPort,
    toNodeId: toNode,
    toPort: "in"
  )
}

private struct DefaultPolicyNodeSpec {
  let id: String
  let title: String
  let kind: TaskBoardPolicyPipelineNodeKind
  let groupID: String
  let outputs: [String]
}

private let defaultPolicyNodeSpecs: [DefaultPolicyNodeSpec] = [
  DefaultPolicyNodeSpec(
    id: "action:router",
    title: "Action gate",
    kind: TaskBoardPolicyPipelineNodeKind(kind: "action_gate", actions: [.spawnAgent]),
    groupID: "entry",
    outputs: ["default", "mutate", "merge", "unsafe"]
  ),
  DefaultPolicyNodeSpec(
    id: "evidence:merge",
    title: "Merge evidence",
    kind: TaskBoardPolicyPipelineNodeKind(kind: "evidence_check"),
    groupID: "merge",
    outputs: ["pass", "fail", "consensus", "missing"]
  ),
  DefaultPolicyNodeSpec(
    id: "risk:merge",
    title: "Merge risk",
    kind: TaskBoardPolicyPipelineNodeKind(kind: "risk_classifier"),
    groupID: "merge",
    outputs: ["low_or_equal", "high", "missing"]
  ),
  DefaultPolicyNodeSpec(
    id: "supervisor:default-allow",
    title: "supervisor:default-allow",
    kind: TaskBoardPolicyPipelineNodeKind(kind: "supervisor_rule"),
    groupID: "terminal",
    outputs: []
  ),
  DefaultPolicyNodeSpec(
    id: "dry_run:mutate_repo",
    title: "dry_run:mutate_repo",
    kind: TaskBoardPolicyPipelineNodeKind(kind: "dry_run_gate"),
    groupID: "terminal",
    outputs: []
  ),
  DefaultPolicyNodeSpec(
    id: "human:unsafe-action",
    title: "human:unsafe-action",
    kind: TaskBoardPolicyPipelineNodeKind(kind: "human_gate"),
    groupID: "terminal",
    outputs: []
  ),
  DefaultPolicyNodeSpec(
    id: "human:missing-merge-evidence",
    title: "human:missing-merge-evidence",
    kind: TaskBoardPolicyPipelineNodeKind(kind: "human_gate"),
    groupID: "terminal",
    outputs: []
  ),
  DefaultPolicyNodeSpec(
    id: "consensus:protected-path",
    title: "consensus:protected-path",
    kind: TaskBoardPolicyPipelineNodeKind(kind: "consensus_gate"),
    groupID: "terminal",
    outputs: []
  ),
  DefaultPolicyNodeSpec(
    id: "dry_run:high-risk-merge",
    title: "dry_run:high-risk-merge",
    kind: TaskBoardPolicyPipelineNodeKind(kind: "dry_run_gate"),
    groupID: "terminal",
    outputs: []
  ),
  DefaultPolicyNodeSpec(
    id: "supervisor:merge-deny",
    title: "supervisor:merge-deny",
    kind: TaskBoardPolicyPipelineNodeKind(kind: "supervisor_rule"),
    groupID: "terminal",
    outputs: []
  ),
  DefaultPolicyNodeSpec(
    id: "supervisor:auto-merge",
    title: "supervisor:auto-merge",
    kind: TaskBoardPolicyPipelineNodeKind(kind: "supervisor_rule"),
    groupID: "terminal",
    outputs: []
  ),
]
