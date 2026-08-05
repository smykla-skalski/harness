import SwiftUI

struct DashboardAgentsRouteHeader: View {
  let countText: String
  let sourceLabel: String?
  let isLoading: Bool
  let canCreateAgent: Bool
  let createTerminalAgent: () -> Void
  let createCodexAgent: () -> Void
  let createAcpAgent: () -> Void
  let refresh: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Agents")
          .scaledFont(.title3.weight(.semibold))
        Text(countText)
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      createButton(
        title: "New terminal agent",
        accessibilityIdentifier: HarnessMonitorAccessibility.dashboardTerminalCreateButton,
        action: createTerminalAgent
      )
      createButton(
        title: "New Codex agent",
        accessibilityIdentifier: HarnessMonitorAccessibility.dashboardCodexCreateButton,
        action: createCodexAgent
      )
      createButton(title: "New ACP agent", action: createAcpAgent)
      if let sourceLabel {
        Text(sourceLabel)
          .scaledFont(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.quaternary, in: Capsule())
      }
      Button(action: refresh) {
        if isLoading {
          ProgressView()
            .controlSize(.small)
        } else {
          Label("Refresh Agents", systemImage: "arrow.clockwise")
            .labelStyle(.iconOnly)
        }
      }
      .buttonStyle(.borderless)
      .help("Refresh agents")
      .accessibilityLabel("Refresh agents")
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAgentsRefreshButton)
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 54)
  }

  @ViewBuilder
  private func createButton(
    title: String,
    accessibilityIdentifier: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    let button = Button(action: action) {
      Label(title, systemImage: "plus")
    }
    .disabled(!canCreateAgent)
    if let accessibilityIdentifier {
      button.accessibilityIdentifier(accessibilityIdentifier)
    } else {
      button
    }
  }
}
