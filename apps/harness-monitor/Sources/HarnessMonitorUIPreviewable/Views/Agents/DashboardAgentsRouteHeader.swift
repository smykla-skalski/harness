import SwiftUI

struct DashboardAgentsRouteHeader: View {
  private enum ActionPresentation {
    case full
    case compact
    case icons
  }

  private struct CreateButtonConfiguration {
    let title: String
    let compactTitle: String
    let compactSystemImage: String
    let accessibilityIdentifier: String?
  }

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
      title
        .fixedSize(horizontal: true, vertical: false)
      Spacer(minLength: 0)
      ViewThatFits(in: .horizontal) {
        controls(actionPresentation: .full)
        controls(actionPresentation: .compact)
        controls(actionPresentation: .icons)
      }
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 54)
  }

  private var title: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Agents")
        .scaledFont(.title3.weight(.semibold))
      Text(countText)
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func controls(actionPresentation: ActionPresentation) -> some View {
    HStack(spacing: 12) {
      createActions(presentation: actionPresentation)
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
  }

  private func createActions(presentation: ActionPresentation) -> some View {
    HStack(spacing: 12) {
      createButton(
        configuration: CreateButtonConfiguration(
          title: "New terminal agent",
          compactTitle: "Terminal",
          compactSystemImage: "terminal",
          accessibilityIdentifier: HarnessMonitorAccessibility.dashboardTerminalCreateButton
        ),
        presentation: presentation,
        action: createTerminalAgent
      )
      createButton(
        configuration: CreateButtonConfiguration(
          title: "New Codex agent",
          compactTitle: "Codex",
          compactSystemImage: "chevron.left.forwardslash.chevron.right",
          accessibilityIdentifier: HarnessMonitorAccessibility.dashboardCodexCreateButton
        ),
        presentation: presentation,
        action: createCodexAgent
      )
      createButton(
        configuration: CreateButtonConfiguration(
          title: "New ACP agent",
          compactTitle: "ACP",
          compactSystemImage: "network",
          accessibilityIdentifier: nil
        ),
        presentation: presentation,
        action: createAcpAgent
      )
    }
  }

  @ViewBuilder
  private func createButton(
    configuration: CreateButtonConfiguration,
    presentation: ActionPresentation,
    action: @escaping () -> Void
  ) -> some View {
    let button = Button(action: action) {
      switch presentation {
      case .full:
        Label(configuration.title, systemImage: "plus")
      case .compact:
        Label(configuration.compactTitle, systemImage: configuration.compactSystemImage)
      case .icons:
        Label(configuration.title, systemImage: configuration.compactSystemImage)
          .labelStyle(.iconOnly)
      }
    }
    .help(configuration.title)
    .accessibilityLabel(configuration.title)
    .disabled(!canCreateAgent)
    if let accessibilityIdentifier = configuration.accessibilityIdentifier {
      button.accessibilityIdentifier(accessibilityIdentifier)
    } else {
      button
    }
  }
}
