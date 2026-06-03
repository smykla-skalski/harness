import SwiftUI

public func policyCanvasResolvedPortSide(for endpoint: PolicyCanvasPortEndpoint) -> PolicyCanvasPortSide {
  endpoint.side ?? (endpoint.kind == .input ? .leading : .trailing)
}
