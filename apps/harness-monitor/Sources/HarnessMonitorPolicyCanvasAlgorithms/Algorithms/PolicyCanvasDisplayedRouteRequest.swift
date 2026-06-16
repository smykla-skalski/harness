import SwiftUI

public func policyCanvasResolvedPortSide(for endpoint: PolicyCanvasPortEndpoint)
  -> PolicyCanvasPortSide
{
  switch endpoint.side {
  case .some(.leading):
    .leading
  case .some(.trailing):
    .trailing
  case .some(.top), .some(.bottom), .none:
    endpoint.kind == .input ? .leading : .trailing
  }
}

public func policyCanvasResolvedRoutablePortSide(
  for endpoint: PolicyCanvasPortEndpoint,
  preferredSide: PolicyCanvasPortSide?
) -> PolicyCanvasPortSide {
  let sides = policyCanvasRoutablePortSides(for: endpoint.kind)
  if let preferredSide, sides.contains(preferredSide) {
    return preferredSide
  }
  return policyCanvasResolvedPortSide(for: endpoint)
}
