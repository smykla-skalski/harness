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

  func overlappingDefaultPolicyDocument(revision: UInt64) -> PolicyPipelineDocument {
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
