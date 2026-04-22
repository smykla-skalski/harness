import HarnessMonitorKit
import SwiftUI

/// Toolbar bell-with-badge for the Monitor supervisor. Phase 1 hard-codes grey and a zero
/// badge; Phase 2 worker 18 tints by `slice.maxSeverity` and overlays the real open count.
public struct SupervisorToolbarItem: View {
  @Environment(\.openWindow)
  private var openWindow

  private let slice: SupervisorToolbarSlice

  public init(slice: SupervisorToolbarSlice) {
    self.slice = slice
  }

  public var body: some View {
    Button {
      openWindow(id: HarnessMonitorWindowID.decisions)
    } label: {
      Label("Decisions", systemImage: "bell.badge")
    }
    .help("Open Decisions window")
    .accessibilityIdentifier(HarnessMonitorAccessibility.supervisorBadge)
  }
}

#Preview("Supervisor Toolbar Item — empty") {
  SupervisorToolbarItem(slice: SupervisorToolbarSlice())
    .padding()
}
