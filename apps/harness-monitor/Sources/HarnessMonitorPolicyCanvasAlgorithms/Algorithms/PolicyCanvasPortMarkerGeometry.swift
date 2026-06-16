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
  // Keep automatic terminals on horizontal edges. Vertical sides are still
  // addressable by explicit anchor helpers, but routed canvas markers should not
  // spill to the top or bottom of a node when a side is crowded.
  switch kind {
  case .input:
    [.leading, .trailing]
  case .output:
    [.trailing, .leading]
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
