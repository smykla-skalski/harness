import SwiftUI

public func policyCanvasCanonicalPortEndpoint(
  _ endpoint: PolicyCanvasPortEndpoint
) -> PolicyCanvasPortEndpoint {
  PolicyCanvasPortEndpoint(
    nodeID: endpoint.nodeID,
    portID: endpoint.portID,
    kind: endpoint.kind
  )
}

public func policyCanvasRoutablePortSides(for kind: PolicyCanvasPortKind) -> [PolicyCanvasPortSide]
{
  // Must mirror `PolicyCanvasViewModel.routablePortSides`: inputs default to the
  // leading edge and outputs to the trailing edge, with in-flow vertical sides
  // ahead of overflow fallbacks. The opposite horizontal side is last, but still
  // admitted: same-group preferred-side assignment deliberately uses trailing
  // inputs and leading outputs for back edges.
  switch kind {
  case .input:
    [.leading, .top, .bottom, .trailing]
  case .output:
    [.trailing, .bottom, .top, .leading]
  }
}

public func policyCanvasShiftedRouteAnchor(
  _ point: CGPoint,
  side: PolicyCanvasPortSide,
  terminal: PolicyCanvasPortTerminal
) -> CGPoint {
  switch side {
  case .leading, .trailing:
    CGPoint(x: point.x, y: point.y + terminal.axisOffset)
  case .top, .bottom:
    CGPoint(x: point.x + terminal.axisOffset, y: point.y)
  }
}
