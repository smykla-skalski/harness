import HarnessMonitorKit
import SwiftUI

/// Placeholder Decisions detail column. Phase 2 worker 20 fills header + context + suggested
/// actions + audit trail + live tick. Phase 1 shows an empty-state message so the window has
/// something to render on first launch.
public struct DecisionDetailView: View {
  public init() {}

  public var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "bell.badge")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text("Select a decision")
        .font(.title3)
      Text("The Monitor supervisor will surface decisions here.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionDetail)
  }
}

#Preview("Decision Detail — empty") {
  DecisionDetailView()
    .frame(width: 600, height: 480)
}
