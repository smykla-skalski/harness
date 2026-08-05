import HarnessMonitorKit
import SwiftUI

struct DashboardAgentDetailPane: View {
  let store: HarnessMonitorStore
  let agent: DashboardAgentSummary?
  let decisions: [DashboardDecisionItem]
  let loadsTerminalDetailAutomatically: Bool
  let loadsAcpDetailAutomatically: Bool
  let loadsCodexDetailAutomatically: Bool
  let onTerminalMembershipRemoved: () -> Void
  @State private var terminalState: DashboardTerminalAgentDetailState
  @State private var acpState: DashboardAcpAgentDetailState
  @State private var codexState: DashboardCodexAgentDetailState

  init(
    store: HarnessMonitorStore,
    agent: DashboardAgentSummary?,
    decisions: [DashboardDecisionItem] = [],
    loadsTerminalDetailAutomatically: Bool = true,
    loadsAcpDetailAutomatically: Bool = true,
    loadsCodexDetailAutomatically: Bool = true,
    initialTerminalDetail: DashboardTerminalAgentDetail? = nil,
    initialAcpDetail: DashboardAcpAgentDetail? = nil,
    initialCodexDetail: DashboardCodexAgentDetail? = nil,
    onTerminalMembershipRemoved: @escaping () -> Void = {}
  ) {
    self.store = store
    self.agent = agent
    self.decisions = decisions
    self.loadsTerminalDetailAutomatically = loadsTerminalDetailAutomatically
    self.loadsAcpDetailAutomatically = loadsAcpDetailAutomatically
    self.loadsCodexDetailAutomatically = loadsCodexDetailAutomatically
    self.onTerminalMembershipRemoved = onTerminalMembershipRemoved
    _terminalState = State(
      initialValue: DashboardTerminalAgentDetailState(
        detail: initialTerminalDetail,
        agentID: agent?.managedAgentID
      )
    )
    _acpState = State(initialValue: DashboardAcpAgentDetailState(detail: initialAcpDetail))
    _codexState = State(initialValue: DashboardCodexAgentDetailState(detail: initialCodexDetail))
  }

  private var teamDecisions: [DashboardDecisionItem] {
    decisions.filter(\.isTeamDecision)
  }

  var body: some View {
    Group {
      if let agent {
        if agent.runtimeKind == .terminal {
          DashboardTerminalAgentDetailView(
            store: store,
            agent: agent,
            state: terminalState,
            teamDecisions: teamDecisions,
            loadsAutomatically: loadsTerminalDetailAutomatically,
            onMembershipRemoved: onTerminalMembershipRemoved
          )
        } else if agent.runtimeKind == .acp {
          DashboardAcpAgentDetailView(
            store: store,
            agent: agent,
            state: acpState,
            teamDecisions: teamDecisions,
            loadsAutomatically: loadsAcpDetailAutomatically
          )
        } else if agent.runtimeKind == .codex {
          DashboardCodexAgentDetailView(
            store: store,
            agent: agent,
            state: codexState,
            teamDecisions: teamDecisions,
            loadsAutomatically: loadsCodexDetailAutomatically
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
    DashboardDecisionScrollView(store: store, decisionIDs: Set(teamDecisions.map(\.id))) {
      VStack(alignment: .leading, spacing: 20) {
        DashboardAgentDetailHeader(agent: agent)
        DashboardAgentDecisionsSection(store: store, items: teamDecisions)
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
