import HarnessMonitorKit
import SwiftUI

/// Context panel rendered inside the Decisions detail column. Phase 2 worker 20 fills this
/// with snapshot excerpt, related timeline, observer issues, and recent supervisor actions.
public struct DecisionContextPanel: View {
  public init() {}

  public var body: some View {
    EmptyView()
      .accessibilityIdentifier(HarnessMonitorAccessibility.decisionContextPanel)
  }
}

#Preview("Decision Context — empty") {
  DecisionContextPanel()
    .frame(width: 420, height: 320)
}
