import HarnessMonitorKit
import SwiftUI

/// Supervisor notifications pane stub. Phase 2 worker 23 replaces the body with per-severity
/// channel toggles.
public struct PreferencesSupervisorNotificationsPane: View {
  public init() {}

  public var body: some View {
    ContentUnavailableView(
      "Notifications coming soon",
      systemImage: "bell.badge",
      description: Text("Phase 2 wires the per-severity channel toggles.")
    )
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesSupervisorPane("notifications")
    )
  }
}

#Preview("Supervisor Notifications Pane — empty") {
  PreferencesSupervisorNotificationsPane()
    .frame(width: 600, height: 400)
}
