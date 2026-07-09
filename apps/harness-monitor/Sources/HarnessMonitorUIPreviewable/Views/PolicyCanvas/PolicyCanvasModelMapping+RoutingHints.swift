// Companion to PolicyCanvasModelMapping.swift.
// Routing-hint and port-side mapping helpers that convert between the
// canvas and daemon data models.
import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels
import SwiftUI

func policyCanvasRoutingHints(
  from layout: PolicyPipelineLayout
) -> PolicyCanvasLayoutRoutingHints? {
  guard !layout.routingHints.isEmpty else {
    return nil
  }
  return PolicyCanvasLayoutRoutingHints(
    edgeHints: Dictionary(
      layout.routingHints.map { hint in
        (
          hint.edgeId,
          PolicyCanvasEdgeCorridorHint(
            key: PolicyCanvasRouteCorridorKey(
              sourceScopeID: hint.sourceScopeId,
              targetScopeID: hint.targetScopeId,
              targetNodeID: hint.targetNodeId,
              label: hint.label,
              laneIndex: hint.laneIndex
            ),
            horizontalLaneY: CGFloat(hint.horizontalLaneY),
            verticalLaneX: hint.verticalLaneX.map { CGFloat($0) },
            bundleOrdinal: hint.bundleOrdinal,
            bundleSize: hint.bundleSize
          )
        )
      },
      uniquingKeysWith: { _, latest in latest }
    )
  )
}

func policyRoutingHints(
  _ routingHints: PolicyCanvasLayoutRoutingHints?
) -> [PolicyPipelineEdgeRoutingHint] {
  guard let routingHints else {
    return []
  }
  return routingHints.edgeHints.keys.sorted().compactMap { edgeID in
    guard let hint = routingHints.edgeHints[edgeID] else {
      return nil
    }
    return PolicyPipelineEdgeRoutingHint(
      edgeId: edgeID,
      sourceScopeId: hint.key.sourceScopeID,
      targetScopeId: hint.key.targetScopeID,
      targetNodeId: hint.key.targetNodeID,
      label: hint.key.label,
      laneIndex: hint.key.laneIndex,
      horizontalLaneY: Double(hint.horizontalLaneY),
      verticalLaneX: hint.verticalLaneX.map { Double($0) },
      bundleOrdinal: hint.bundleOrdinal,
      bundleSize: hint.bundleSize
    )
  }
}

func policyCanvasKind(
  for kind: PolicyGraphNodeKind
) -> PolicyCanvasNodeKind {
  PolicyCanvasNodeKind(rawValue: kind.discriminator)
    ?? {
      switch kind.discriminator {
      case "human_gate", "consensus_gate":
        .humanGate
      case "supervisor_rule":
        .supervisorRule
      case "finish":
        .finish
      case "trigger":
        .trigger
      default:
        .evidenceCheck
      }
    }()
}

func policyCanvasApplyingPreferredPortSides(
  _ edge: PolicyCanvasEdge,
  nodes: [PolicyCanvasNode],
  preservesPinnedState: Bool = false
) -> PolicyCanvasEdge {
  policyCanvasApplyingPreferredPortSides(
    edge,
    nodeLookup: PolicyCanvasNodeLookup(nodes: nodes),
    preservesPinnedState: preservesPinnedState
  )
}

func policyCanvasApplyingPreferredPortSides(
  _ edge: PolicyCanvasEdge,
  nodeLookup: PolicyCanvasNodeLookup,
  preservesPinnedState: Bool = false
) -> PolicyCanvasEdge {
  var adjustedEdge = edge
  var source = adjustedEdge.source
  var target = adjustedEdge.target
  source.side = nil
  target.side = nil
  policyCanvasAssignPreferredPortSides(source: &source, target: &target, nodeLookup: nodeLookup)
  adjustedEdge.source = source
  adjustedEdge.target = target
  adjustedEdge.pinnedPortSide =
    preservesPinnedState
    ? edge.pinnedPortSide
    : (source.side != nil || target.side != nil)
  return adjustedEdge
}
