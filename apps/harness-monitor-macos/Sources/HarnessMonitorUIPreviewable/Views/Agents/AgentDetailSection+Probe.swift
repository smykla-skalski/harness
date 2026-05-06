import HarnessMonitorKit
import SwiftUI

struct AgentDetailCardProbeModifier: ViewModifier {
  let name: String
  let agentID: String

  func body(content: Content) -> some View {
    content
      .accessibilityTestProbe(
        HarnessMonitorAccessibility.workspaceDetailCard,
        label: name,
        value: agentID
      )
      .accessibilityFrameMarker("\(HarnessMonitorAccessibility.workspaceDetailCard).frame")
  }
}

extension View {
  func agentDetailCardProbe(name: String, agentID: String) -> some View {
    modifier(AgentDetailCardProbeModifier(name: name, agentID: agentID))
  }
}
