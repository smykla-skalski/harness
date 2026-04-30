import HarnessMonitorKit
import SwiftUI

/// Toolbar bell-with-badge for the Monitor supervisor.
public struct SupervisorToolbarItem: View {
  @Environment(\.openWindow)
  private var openWindow

  private let store: HarnessMonitorStore
  private let slice: SupervisorToolbarSlice

  public init(store: HarnessMonitorStore, slice: SupervisorToolbarSlice) {
    self.store = store
    self.slice = slice
  }

  public var body: some View {
    @Bindable var slice = slice

    Button {
      store.requestWorkspaceSelection(.decisions(sessionID: store.selectedSessionID))
      openWindow(id: HarnessMonitorWindowID.workspace)
    } label: {
      Label("Needs Attention", systemImage: toolbarSymbolName(for: slice.count))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(toolbarTint(for: slice.maxSeverity))
        .overlay(alignment: .topTrailing) {
          if slice.count > .zero {
            badge(count: slice.count, maxSeverity: slice.maxSeverity)
          }
        }
    }
    .help("Open items needing attention in the workspace")
    .accessibilityIdentifier(HarnessMonitorAccessibility.supervisorBadge)
    .accessibilityLabel("Needs attention")
    .accessibilityValue(
      attentionAccessibilityValue(count: slice.count, maxSeverity: slice.maxSeverity)
    )
    .harnessUITestValue(
      badgeStateLabel(count: slice.count, maxSeverity: slice.maxSeverity)
    )
  }

  private func toolbarTint(for severity: DecisionSeverity?) -> Color {
    switch severity {
    case .none, .info:
      return .secondary
    case .warn, .needsUser:
      return .orange
    case .critical:
      return .red
    }
  }

  private func toolbarSymbolName(for count: Int) -> String {
    count > 0 ? "bell.badge.fill" : "bell.badge"
  }

  private func badgeStateLabel(count: Int, maxSeverity: DecisionSeverity?) -> String {
    """
    count=\(count) severity=\(severityLabel(for: maxSeverity)) \
    tint=\(tintLabel(for: maxSeverity)) symbol=\(toolbarSymbolName(for: count))
    """
  }

  private func severityLabel(for severity: DecisionSeverity?) -> String {
    severity?.rawValue ?? "none"
  }

  private func tintLabel(for severity: DecisionSeverity?) -> String {
    switch severity {
    case .none, .info:
      return "secondary"
    case .warn, .needsUser:
      return "orange"
    case .critical:
      return "red"
    }
  }

  private func attentionAccessibilityValue(count: Int, maxSeverity: DecisionSeverity?) -> String {
    guard count > .zero else { return "No items need attention" }

    let itemLabel = count == 1 ? "item" : "items"
    return "\(count) \(itemLabel), \(spokenSeverityLabel(for: maxSeverity))"
  }

  private func spokenSeverityLabel(for severity: DecisionSeverity?) -> String {
    switch severity {
    case .none, .info:
      "informational"
    case .warn:
      "warning"
    case .needsUser:
      "action needed"
    case .critical:
      "critical"
    }
  }

  @ViewBuilder
  private func badge(count: Int, maxSeverity: DecisionSeverity?) -> some View {
    Text(count.formatted())
      .font(.caption2.weight(.semibold))
      .monospacedDigit()
      .foregroundStyle(.white)
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(Capsule().fill(toolbarTint(for: maxSeverity)))
      .offset(x: 8, y: -8)
      .accessibilityHidden(true)
  }
}

#Preview("Supervisor Toolbar Item — empty") {
  SupervisorToolbarItem(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    slice: SupervisorToolbarSlice()
  )
  .padding()
}
