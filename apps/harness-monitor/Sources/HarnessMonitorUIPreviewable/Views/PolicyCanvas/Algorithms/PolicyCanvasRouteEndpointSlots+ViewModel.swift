import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

@MainActor
func policyCanvasRouteAnchorCandidates(
  for endpoint: PolicyCanvasPortEndpoint,
  in viewModel: PolicyCanvasViewModel,
  terminalSlot: PolicyCanvasRouteEndpointSlot,
  terminal: PolicyCanvasPortTerminal? = nil
) -> [PolicyCanvasRouteAnchorCandidate] {
  let candidates =
    terminal.map { terminal in
      viewModel.portAnchorCandidates(for: endpoint).filter { $0.side == terminal.side }
    } ?? viewModel.portAnchorCandidates(for: endpoint)
  return candidates.map { candidate in
    (
      point: terminal.map {
        policyCanvasShiftedRouteAnchor(candidate.point, side: candidate.side, terminal: $0)
      }
        ?? policyCanvasShiftedRouteAnchor(
          candidate.point,
          side: candidate.side,
          endpoint: endpoint,
          viewModel: viewModel,
          terminalSlot: terminalSlot
        ),
      side: candidate.side
    )
  }
}

@MainActor
func policyCanvasRouteAnchorCandidate(
  for endpoint: PolicyCanvasPortEndpoint,
  side: PolicyCanvasPortSide,
  in viewModel: PolicyCanvasViewModel,
  terminalSlot: PolicyCanvasRouteEndpointSlot
) -> PolicyCanvasRouteAnchorCandidate? {
  if let candidate = policyCanvasRouteAnchorCandidates(
    for: endpoint,
    in: viewModel,
    terminalSlot: terminalSlot
  )
  .first(where: { $0.side == side }) {
    return candidate
  }
  guard let point = viewModel.portAnchor(for: endpoint) else {
    return nil
  }
  return (
    point: policyCanvasShiftedRouteAnchor(
      point,
      side: side,
      endpoint: endpoint,
      viewModel: viewModel,
      terminalSlot: terminalSlot
    ),
    side: side
  )
}

@MainActor
private func policyCanvasShiftedRouteAnchor(
  _ point: CGPoint,
  side: PolicyCanvasPortSide,
  endpoint: PolicyCanvasPortEndpoint,
  viewModel: PolicyCanvasViewModel,
  terminalSlot: PolicyCanvasRouteEndpointSlot
) -> CGPoint {
  let spacing = max(
    viewModel.portSpacing(for: endpoint, side: side),
    PolicyCanvasLayout.defaultEdgeLineSpacing + PolicyCanvasVisibilityRouter.channelStep
  )
  guard let node = viewModel.node(endpoint.nodeID) else {
    return point
  }
  let frame = CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize)
  return policyCanvasShiftedRouteAnchor(
    point,
    side: side,
    frame: frame,
    spacing: spacing,
    terminalSlot: terminalSlot
  )
}
