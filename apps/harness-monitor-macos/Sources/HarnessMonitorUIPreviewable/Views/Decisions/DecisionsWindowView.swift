import HarnessMonitorKit
import SwiftUI

/// Root view for the Monitor supervisor Decisions window. Phase 1 ships an empty placeholder
/// structure that mirrors the Preferences `NavigationSplitView` pattern. Phase 2 worker 19
/// fills the sidebar and worker 20 fills the detail surface.
public struct DecisionsWindowView: View {
  @State private var selection: String?

  public init() {}

  public var body: some View {
    NavigationSplitView {
      DecisionsSidebar(decisions: [], selection: $selection)
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
    } detail: {
      DecisionDetailView()
    }
    .navigationSplitViewStyle(.balanced)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsWindow)
  }
}

#Preview("Decisions Window — empty") {
  DecisionsWindowView()
    .frame(width: 900, height: 640)
}
