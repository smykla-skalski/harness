import HarnessMonitorKit
import SwiftUI

struct DashboardAgentsIssueBanner: View {
  let state: DashboardAgentBrowserViewState

  var body: some View {
    if let issue = state.issue {
      HStack(spacing: 8) {
        Image(systemName: issue.systemImage)
        Text(issue.message(hasCachedAgents: !state.agents.isEmpty))
          .lineLimit(2)
        Spacer()
      }
      .scaledFont(.callout)
      .foregroundStyle(issue.tint)
      .padding(.horizontal, 16)
      .padding(.vertical, 9)
      .background(issue.tint.opacity(0.08))
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAgentsLoadState)
    }
  }
}

extension DashboardAgentLoadIssue {
  var systemImage: String {
    switch self {
    case .offline: "wifi.slash"
    case .requestFailure: "exclamationmark.triangle"
    }
  }

  var tint: Color {
    switch self {
    case .offline: HarnessMonitorTheme.caution
    case .requestFailure: HarnessMonitorTheme.danger
    }
  }

  func message(hasCachedAgents: Bool) -> String {
    switch self {
    case .offline(let reason):
      hasCachedAgents
        ? "Offline — showing cached agents — \(reason.withoutTrailingPeriod)"
        : "Offline — no cached agents available — \(reason.withoutTrailingPeriod)"
    case .requestFailure(let message):
      hasCachedAgents
        ? "Refresh failed — unaffected workspaces remain visible — \(message.withoutTrailingPeriod)"
        : "Agent request failed — \(message.withoutTrailingPeriod)"
    }
  }
}

struct DashboardAgentsRefreshContext: Hashable {
  let isVisible: Bool
  let connection: String
  let sessionIDs: [String]
}

extension HarnessMonitorStore.ConnectionState {
  var refreshIdentity: String {
    switch self {
    case .idle: "idle"
    case .connecting: "connecting"
    case .online: "online"
    case .offline(let message): "offline:\(message)"
    }
  }
}
