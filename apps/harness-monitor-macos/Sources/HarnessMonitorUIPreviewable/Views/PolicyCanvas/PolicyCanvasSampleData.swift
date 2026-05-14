import SwiftUI

extension PolicyCanvasViewModel {
  static func sample() -> PolicyCanvasViewModel {
    let nodes = sampleNodes()
    return PolicyCanvasViewModel(
      nodes: nodes,
      groups: sampleGroups(),
      edges: sampleEdges(),
      selection: .node("risk-score")
    )
  }

  private static func sampleNodes() -> [PolicyCanvasNode] {
    var source = PolicyCanvasNode(
      id: "policy-source",
      title: "Policy intake",
      kind: .source,
      position: CGPoint(x: 120, y: 140)
    )
    source.groupID = "group-intake"

    var risk = PolicyCanvasNode(
      id: "risk-score",
      title: "Risk score",
      kind: .condition,
      position: CGPoint(x: 360, y: 112)
    )
    risk.groupID = "group-evaluation"

    var approval = PolicyCanvasNode(
      id: "review-gate",
      title: "Review gate",
      kind: .review,
      position: CGPoint(x: 590, y: 220)
    )
    approval.groupID = "group-evaluation"

    var context = PolicyCanvasNode(
      id: "context-map",
      title: "Context map",
      kind: .transform,
      position: CGPoint(x: 580, y: 86)
    )
    context.groupID = "group-evaluation"

    var promote = PolicyCanvasNode(
      id: "promote-release",
      title: "Promote release",
      kind: .decision,
      position: CGPoint(x: 840, y: 160)
    )
    promote.groupID = "group-release"

    return [source, risk, context, approval, promote]
  }

  private static func sampleGroups() -> [PolicyCanvasGroup] {
    [
      PolicyCanvasGroup(
        id: "group-intake",
        title: "Input contract",
        frame: CGRect(x: 72, y: 84, width: 236, height: 210),
        tone: .intake
      ),
      PolicyCanvasGroup(
        id: "group-evaluation",
        title: "Evaluation",
        frame: CGRect(x: 326, y: 54, width: 446, height: 334),
        tone: .evaluation
      ),
      PolicyCanvasGroup(
        id: "group-release",
        title: "Promotion",
        frame: CGRect(x: 802, y: 104, width: 248, height: 220),
        tone: .release
      ),
    ]
  }

  private static func sampleEdges() -> [PolicyCanvasEdge] {
    [
      sampleEdge(
        id: "edge-intake-risk",
        source: ("policy-source", "output-event"),
        target: ("risk-score", "input-event"),
        label: "normalize"
      ),
      sampleEdge(
        id: "edge-risk-context",
        source: ("risk-score", "output-pass"),
        target: ("context-map", "input-context"),
        label: "low risk"
      ),
      sampleEdge(
        id: "edge-risk-review",
        source: ("risk-score", "output-fail"),
        target: ("review-gate", "input-policy"),
        label: "needs review"
      ),
      sampleEdge(
        id: "edge-context-promote",
        source: ("context-map", "output-mapped"),
        target: ("promote-release", "input-result"),
        label: "allow"
      ),
      sampleEdge(
        id: "edge-review-promote",
        source: ("review-gate", "output-approved"),
        target: ("promote-release", "input-result"),
        label: "approved"
      ),
    ]
  }

  private static func sampleEdge(
    id: String,
    source: (nodeID: String, portID: String),
    target: (nodeID: String, portID: String),
    label: String
  ) -> PolicyCanvasEdge {
    PolicyCanvasEdge(
      id: id,
      source: PolicyCanvasPortEndpoint(
        nodeID: source.nodeID,
        portID: source.portID,
        kind: .output
      ),
      target: PolicyCanvasPortEndpoint(
        nodeID: target.nodeID,
        portID: target.portID,
        kind: .input
      ),
      label: label
    )
  }
}
