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
  // leading edge and outputs to the trailing edge, with the in-flow vertical side
  // next (top for inputs, bottom for outputs). The opposite vertical side is
  // appended last so it is only an overflow fallback - geometry-aware side
  // selection still picks it explicitly when a target sits above (output exits
  // top) or below (input enters bottom). The port markers follow the route's
  // resolved side, so this list must admit every side the router can pick.
  switch kind {
  case .input:
    [.leading, .top, .bottom]
  case .output:
    [.trailing, .bottom, .top]
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
