import HarnessMonitorKit
import SwiftUI

/// Placeholder Decisions sidebar. Phase 2 worker 19 replaces the body with a `ScrollView` +
/// `LazyVStack` grouping per memory `feedback_sidebar_no_list.md`, severity chips, and query
/// filtering. Phase 1 ships the empty shell only.
public struct DecisionsSidebar: View {
  public init() {}

  public var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 8) {
        Text("No decisions yet")
          .foregroundStyle(.secondary)
          .padding()
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 12)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsSidebar)
  }
}

#Preview("Decisions Sidebar — empty") {
  DecisionsSidebar()
    .frame(width: 260, height: 480)
}
