import HarnessMonitorKit
import SwiftUI

/// Supervisor rules pane stub. Phase 2 worker 22 replaces the body with per-rule enable +
/// behavior + parameter editors. Phase 1 ships an empty shell so the section switch compiles.
public struct PreferencesSupervisorRulesPane: View {
  public init() {}

  public var body: some View {
    ContentUnavailableView(
      "Rules coming soon",
      systemImage: "slider.horizontal.3",
      description: Text("Phase 2 wires the per-rule editors.")
    )
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesSupervisorPane("rules"))
  }
}

#Preview("Supervisor Rules Pane — empty") {
  PreferencesSupervisorRulesPane()
    .frame(width: 600, height: 400)
}
