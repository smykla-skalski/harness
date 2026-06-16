import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

struct PolicyCanvasNodeKindChange: Equatable {
  let id: String
  let from: PolicyCanvasNodeKind
  let to: PolicyCanvasNodeKind
  let fromSubtitle: String
  let toSubtitle: String
  let fromPolicyKind: PolicyGraphNodeKind?
  let toPolicyKind: PolicyGraphNodeKind?
  let removedEdges: [PolicyCanvasEdge]

  var missingNodeInverse: PolicyCanvasChange {
    .setNodeKind(
      id: id,
      from: to,
      to: to,
      fromSubtitle: toSubtitle,
      toSubtitle: toSubtitle,
      fromPolicyKind: toPolicyKind,
      toPolicyKind: toPolicyKind,
      removedEdges: []
    )
  }
}
