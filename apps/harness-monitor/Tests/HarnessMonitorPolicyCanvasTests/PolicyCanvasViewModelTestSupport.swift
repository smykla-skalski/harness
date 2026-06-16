import Foundation
import SwiftUI

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

@MainActor
func waitForPolicyCanvasDirtyReconciliation(_ viewModel: PolicyCanvasViewModel) async {
  var attempts = 0
  while viewModel.documentDirty && attempts < 200 {
    try? await Task.sleep(for: .milliseconds(10))
    attempts += 1
  }
}

extension PolicyCanvasViewModelTests {
  func policyDocument(revision: UInt64) -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [
        TaskBoardPolicyPipelineNode(
          id: "node-intake",
          title: "Ready for dispatch",
          kind: .actionGate(actions: [.spawnAgent]),
          groupId: "group-dispatch",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
          outputs: [TaskBoardPolicyPipelinePort(id: "default", title: "default")]
        ),
        TaskBoardPolicyPipelineNode(
          id: "stuck-agent",
          title: "Stuck agent rule",
          kind: .supervisorRule(decision: .allow, reasonCodes: [.defaultAllow]),
          groupId: "group-dispatch",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")]
        ),
      ],
      edges: [
        TaskBoardPolicyPipelineEdge(
          id: "edge-intake-supervisor",
          fromNodeId: "node-intake",
          fromPort: "default",
          toNodeId: "stuck-agent",
          toPort: "in"
        )
      ],
      groups: [
        TaskBoardPolicyPipelineGroup(
          id: "group-dispatch",
          title: "Dispatch",
          nodeIds: ["node-intake", "stuck-agent"]
        )
      ],
      layout: TaskBoardPolicyPipelineLayout(
        nodes: [
          TaskBoardPolicyPipelineNodeLayout(nodeId: "node-intake", x: 20, y: 40),
          TaskBoardPolicyPipelineNodeLayout(nodeId: "stuck-agent", x: 280, y: 40),
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
          kind: .evidenceCheck(checks: [
            PolicyEvidenceCheck(
              field: .checksGreen,
              pass: .isTrue,
              failReasonCode: .checksNotGreen,
              missingReasonCode: .missingMergeEvidence
            )
          ]),
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
          kind: .riskClassifier(field: .riskScore, threshold: 74, highRiskReasonCode: .riskAboveThreshold, missingReasonCode: .humanRequired),
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

  func overlappingDefaultPolicyDocument(revision: UInt64) -> TaskBoardPolicyPipelineDocument {
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

@MainActor
extension PolicyCanvasViewModel {
  var nodesContainOverlaps: Bool {
    for leftIndex in nodes.indices {
      for rightIndex in nodes.index(after: leftIndex)..<nodes.endIndex {
        let left = CGRect(origin: nodes[leftIndex].position, size: PolicyCanvasLayout.nodeSize)
        let right = CGRect(origin: nodes[rightIndex].position, size: PolicyCanvasLayout.nodeSize)
        if left.intersects(right) {
          return true
        }
      }
    }
    return false
  }
}

func intersects(_ left: CGRect?, _ right: CGRect?) -> Bool {
  guard let left, let right else {
    return false
  }
  return left.intersects(right)
}

extension PolicyCanvasEdgeRoute {
  func segmentsIntersect(rect: CGRect) -> Bool {
    zip(points, points.dropFirst()).contains { start, end in
      if start.x == end.x {
        let yRange = min(start.y, end.y)...max(start.y, end.y)
        return (rect.minX...rect.maxX).contains(start.x)
          && rangesOverlap(yRange, rect.minY...rect.maxY)
      }
      if start.y == end.y {
        let xRange = min(start.x, end.x)...max(start.x, end.x)
        return (rect.minY...rect.maxY).contains(start.y)
          && rangesOverlap(xRange, rect.minX...rect.maxX)
      }
      return CGRect(
        x: min(start.x, end.x),
        y: min(start.y, end.y),
        width: abs(end.x - start.x),
        height: abs(end.y - start.y)
      )
      .intersects(rect)
    }
  }
}

private func rangesOverlap<T: Comparable>(_ left: ClosedRange<T>, _ right: ClosedRange<T>) -> Bool {
  left.lowerBound <= right.upperBound && right.lowerBound <= left.upperBound
}
