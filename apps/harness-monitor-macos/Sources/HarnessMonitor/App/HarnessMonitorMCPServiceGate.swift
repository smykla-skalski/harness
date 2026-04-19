import HarnessMonitorKit
import SwiftUI

/// View modifier that keeps `HarnessMonitorMCPAccessibilityService.shared`
/// in sync with the `@AppStorage` toggle that owns its enabled state. The
/// modifier does not render anything; it relies on `.task(id:)` so the
/// service starts on first appear and stops/restarts when the toggle
/// flips. On app termination the service receives a final `setEnabled(false)`
/// so the socket is closed cleanly.
struct HarnessMonitorMCPServiceGate: ViewModifier {
  @AppStorage(HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
  private var registryHostEnabled = HarnessMonitorMCPPreferencesDefaults
    .registryHostEnabledDefault

  func body(content: Content) -> some View {
    content
      .task(id: registryHostEnabled) {
        await HarnessMonitorMCPAccessibilityService.shared
          .setEnabled(registryHostEnabled)
      }
  }
}

extension View {
  func mcpAccessibilityServiceGate() -> some View {
    modifier(HarnessMonitorMCPServiceGate())
  }
}
