import HarnessMonitorKit
import SwiftUI

/// Supervisor background-activity pane stub. Phase 2 worker 23 replaces the body with the
/// `NSBackgroundActivityScheduler` toggles.
public struct PreferencesSupervisorBackgroundPane: View {
  public init() {}

  public var body: some View {
    ContentUnavailableView(
      "Background coming soon",
      systemImage: "clock.arrow.circlepath",
      description: Text("Phase 2 wires the background-activity toggle.")
    )
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesSupervisorPane("background")
    )
  }
}

#Preview("Supervisor Background Pane — empty") {
  PreferencesSupervisorBackgroundPane()
    .frame(width: 600, height: 400)
}
