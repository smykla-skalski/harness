import HarnessMonitorKit
import SwiftUI

struct DashboardAgentDetailPane: View {
  let store: HarnessMonitorStore
  let agent: DashboardAgentSummary?
  let loadsAcpDetailAutomatically: Bool
  @State private var acpState: DashboardAcpAgentDetailState

  init(
    store: HarnessMonitorStore,
    agent: DashboardAgentSummary?,
    loadsAcpDetailAutomatically: Bool = true,
    initialAcpDetail: DashboardAcpAgentDetail? = nil
  ) {
    self.store = store
    self.agent = agent
    self.loadsAcpDetailAutomatically = loadsAcpDetailAutomatically
    _acpState = State(initialValue: DashboardAcpAgentDetailState(detail: initialAcpDetail))
  }

  var body: some View {
    Group {
      if let agent {
        if agent.runtimeKind == .acp {
          DashboardAcpAgentDetailView(
            store: store,
            agent: agent,
            state: acpState,
            loadsAutomatically: loadsAcpDetailAutomatically
          )
        } else {
          standardDetail(agent)
        }
      } else {
        ContentUnavailableView(
          "Select an agent",
          systemImage: "person.crop.circle.badge.questionmark",
          description: Text("Choose an agent to see its current summary and managed identity")
        )
      }
    }
  }

  private func standardDetail(_ agent: DashboardAgentSummary) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        DashboardAgentDetailHeader(agent: agent)
        DashboardAgentCurrentSummary(agent: agent)
        DashboardAgentIdentityCard(agent: agent)
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAgentDetail)
  }
}

struct DashboardAgentDetailHeader: View {
  let agent: DashboardAgentSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(agent.displayName)
          .scaledFont(.title2.weight(.semibold))
          .textSelection(.enabled)
        Spacer()
        DashboardAgentStatusBadge(agent: agent)
      }

      HStack(spacing: 8) {
        Label(agent.runtimeKind.title, systemImage: agent.runtimeKind.detailSystemImage)
        Text("·")
          .foregroundStyle(.tertiary)
        Text(agent.workspace.title)
        Text("·")
          .foregroundStyle(.tertiary)
        Text(agent.workspace.subtitle)
      }
      .scaledFont(.subheadline)
      .foregroundStyle(.secondary)
      .lineLimit(1)
    }
  }
}

private struct DashboardAgentStatusBadge: View {
  let agent: DashboardAgentSummary

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(agent.lifecycle.detailTint)
        .frame(width: 7, height: 7)
      Text(agent.lifecycle.title)
      if agent.source == .cache {
        Text("Cached")
          .foregroundStyle(.secondary)
      }
    }
    .scaledFont(.caption.weight(.medium))
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(.quaternary, in: Capsule())
    .accessibilityElement(children: .combine)
  }
}

private struct DashboardAgentCurrentSummary: View {
  let agent: DashboardAgentSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Current summary")
        .scaledFont(.headline)
      Text(agent.summary ?? fallbackSummary)
        .foregroundStyle(agent.summary == nil ? .secondary : .primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
  }

  private var fallbackSummary: String {
    agent.source == .cache
      ? "No recent summary is available in the cached snapshot"
      : "This runtime has not reported a summary yet"
  }
}

struct DashboardAgentIdentityCard: View {
  let agent: DashboardAgentSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Identity and workspace")
        .scaledFont(.headline)
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
        DashboardAgentFactRow(title: "Runtime kind", value: agent.runtimeKind.title)
        DashboardAgentFactRow(title: "Managed agent ID", value: agent.managedAgentID)
        DashboardAgentFactRow(title: "Project", value: agent.workspace.title)
        DashboardAgentFactRow(title: "Worktree", value: agent.workspace.subtitle)
        DashboardAgentFactRow(title: "Workspace path", value: agent.projectDirectory)
        DashboardAgentFactRow(title: "Updated", value: agent.updatedAt)
      }
    }
    .padding(16)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct DashboardAgentFactRow: View {
  let title: String
  let value: String

  var body: some View {
    GridRow {
      Text(title)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
      Text(value.isEmpty ? "—" : value)
        .textSelection(.enabled)
        .gridColumnAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scaledFont(.callout)
    .accessibilityElement(children: .combine)
  }
}

extension DashboardAgentRuntimeKind {
  fileprivate var detailSystemImage: String {
    switch self {
    case .terminal: "terminal"
    case .codex: "chevron.left.forwardslash.chevron.right"
    case .acp: "network"
    }
  }
}

extension DashboardAgentLifecycle {
  fileprivate var detailTint: Color {
    switch self {
    case .starting: HarnessMonitorTheme.accent
    case .active: HarnessMonitorTheme.success
    case .waiting: HarnessMonitorTheme.caution
    case .idle, .completed, .stopped, .unknown: .secondary
    case .disconnected, .failed: HarnessMonitorTheme.danger
    }
  }
}
