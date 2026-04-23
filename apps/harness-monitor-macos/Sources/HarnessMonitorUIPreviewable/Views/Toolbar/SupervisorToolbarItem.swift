import HarnessMonitorKit
import SwiftUI

/// Toolbar bell-with-badge for the Monitor supervisor.
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
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(toolbarTint)
        .overlay(alignment: .topTrailing) {
          if slice.count > .zero {
            badge
          }
        }
    }
    .help("Open Decisions window")
    .accessibilityIdentifier(HarnessMonitorAccessibility.supervisorBadge)
  }

  private var toolbarTint: Color {
    switch slice.maxSeverity {
    case .none, .info:
      return .secondary
    case .warn, .needsUser:
      return .orange
    case .critical:
      return .red
    }
  }

  @ViewBuilder private var badge: some View {
    Text(slice.count.formatted())
      .font(.caption2.weight(.semibold))
      .monospacedDigit()
      .foregroundStyle(.white)
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(Capsule().fill(toolbarTint))
      .offset(x: 8, y: -8)
      .accessibilityHidden(true)
  }
}

#Preview("Supervisor Toolbar Item — empty") {
  SupervisorToolbarItem(slice: SupervisorToolbarSlice())
    .padding()
}
