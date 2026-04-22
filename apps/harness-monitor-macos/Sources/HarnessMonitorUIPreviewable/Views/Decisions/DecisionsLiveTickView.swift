import HarnessMonitorKit
import SwiftUI

/// Collapsible live-tick view showing last snapshot id, tick latency (rolling p50/p95), active
/// observer count, and quarantined rules. Phase 2 worker 20 fills the body.
public struct DecisionsLiveTickView: View {
  public init() {}

  public var body: some View {
    EmptyView()
      .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsLiveTick)
  }
}

#Preview("Decisions Live Tick — empty") {
  DecisionsLiveTickView()
    .frame(width: 420, height: 100)
}
