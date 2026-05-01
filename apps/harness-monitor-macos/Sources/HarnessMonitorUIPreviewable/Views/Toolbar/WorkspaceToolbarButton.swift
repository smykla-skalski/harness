import HarnessMonitorKit
import SwiftUI

public struct WorkspaceToolbarButton: View {
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

    Button(action: { openWorkspace(focusesDecisions: slice.count > .zero) }) {
      Label {
        Text("Workspace")
      } icon: {
        toolbarIcon(count: slice.count, maxSeverity: slice.maxSeverity)
      }
    }
    .help(helpText(count: slice.count))
    .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceToolbarButton)
    .accessibilityLabel("Workspace")
    .accessibilityValue(
      attentionAccessibilityValue(count: slice.count, maxSeverity: slice.maxSeverity)
    )
    .harnessUITestValue(
      buttonStateLabel(count: slice.count, maxSeverity: slice.maxSeverity)
    )
  }

  private func openWorkspace(focusesDecisions: Bool) {
    if focusesDecisions {
      store.requestWorkspaceSelection(.decisions(sessionID: store.selectedSessionID))
    }
    openWindow(id: HarnessMonitorWindowID.workspace)
  }

  private func helpText(count: Int) -> String {
    guard count > .zero else {
      return "Open workspace"
    }
    return
      "Open workspace and review \(count.formatted()) "
      + "item\(count == 1 ? "" : "s") needing attention"
  }

  @ViewBuilder
  private func toolbarIcon(count: Int, maxSeverity: DecisionSeverity?) -> some View {
    HarnessMonitorUIAssets.image(named: "ToolbarWorkspaceBot")
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .frame(width: 18, height: 18)
      .foregroundStyle(iconTint(for: maxSeverity))
      .overlay(alignment: .topTrailing) {
        if count > .zero {
          badge(count: count, maxSeverity: maxSeverity)
        }
      }
      .accessibilityHidden(true)
  }

  private func iconTint(for severity: DecisionSeverity?) -> Color {
    switch severity {
    case .warn, .needsUser:
      .orange
    case .critical:
      .red
    case .none, .info:
      .primary
    }
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

  private func buttonStateLabel(count: Int, maxSeverity: DecisionSeverity?) -> String {
    """
    count=\(count) severity=\(severityLabel(for: maxSeverity)) \
    tint=\(tintLabel(for: maxSeverity)) badge=\(count > 0 ? "visible" : "hidden")
    """
  }

  private func severityLabel(for severity: DecisionSeverity?) -> String {
    severity?.rawValue ?? "none"
  }

  private func tintLabel(for severity: DecisionSeverity?) -> String {
    switch severity {
    case .none, .info:
      return "primary"
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

#Preview("Workspace Toolbar Button — empty") {
  WorkspaceToolbarButton(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    slice: SupervisorToolbarSlice()
  )
  .padding()
}
