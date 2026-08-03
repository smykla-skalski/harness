import HarnessMonitorKit
import SwiftUI

struct DashboardAgentsListPane: View {
  let state: DashboardAgentBrowserViewState
  @Binding var selection: DashboardAgentsSelection?
  let decisionSummaries: [DashboardAgentIdentity: DashboardAgentDecisionSummary]
  let workspaceBuckets: [DashboardDecisionWorkspaceBucket]

  var body: some View {
    Group {
      switch state.contentState {
      case .firstRun:
        DashboardAgentsEmptyState(
          title: "Agents are ready to browse",
          message: "Connect to the daemon to load agents from every known workspace",
          systemImage: "person.2"
        )
      case .loading:
        VStack(spacing: 12) {
          ProgressView()
          Text("Loading agents")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .empty:
        DashboardAgentsEmptyState(
          title: state.issue == nil ? "No agents" : "Agents unavailable",
          message: emptyMessage,
          systemImage: emptySystemImage
        )
      case .content:
        agentList
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAgentsList)
  }

  private var sections: [DashboardAgentsListSection] {
    DashboardAgentsListSection.make(groups: state.groups, buckets: workspaceBuckets)
  }

  private var agentList: some View {
    List(selection: $selection) {
      ForEach(sections) { section in
        Section {
          ForEach(section.agents) { agent in
            DashboardAgentListRow(agent: agent, summary: decisionSummaries[agent.identity])
              .tag(DashboardAgentsSelection.agent(agent.identity))
          }
          if let bucket = section.bucket {
            DashboardWorkspaceDecisionsRow(bucket: bucket)
              .tag(DashboardAgentsSelection.workspaceDecisions(bucket.workspace.identity))
          }
        } header: {
          DashboardAgentWorkspaceHeader(workspace: section.workspace)
        }
      }
    }
    .listStyle(.sidebar)
    .accessibilityLabel("Agents by workspace")
  }

  private var emptyMessage: String {
    switch state.issue {
    case .offline(let reason):
      "No cached agents are available while the daemon is offline — \(reason.withoutTrailingPeriod)"
    case .requestFailure(let message):
      "The agent request failed and no cached agents are available — \(message.withoutTrailingPeriod)"
    case nil:
      "Managed agents will appear here when they start in a known project or worktree"
    }
  }

  private var emptySystemImage: String {
    switch state.issue {
    case .offline:
      "wifi.exclamationmark"
    case .requestFailure:
      "exclamationmark.triangle"
    case nil:
      "person.2.slash"
    }
  }
}

/// One workspace's list section: its agents plus an optional agent-less decisions bucket. A bucket
/// can exist without agents, so bucket-only workspaces still get a section.
private struct DashboardAgentsListSection: Identifiable {
  let workspace: DashboardAgentWorkspace
  let agents: [DashboardAgentSummary]
  let bucket: DashboardDecisionWorkspaceBucket?

  var id: DashboardAgentWorkspaceIdentity { workspace.identity }

  static func make(
    groups: [DashboardAgentWorkspaceGroup],
    buckets: [DashboardDecisionWorkspaceBucket]
  ) -> [Self] {
    var bucketsByWorkspace = Dictionary(
      buckets.map { ($0.workspace.identity, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var sections = groups.map { group in
      Self(
        workspace: group.workspace,
        agents: group.agents,
        bucket: bucketsByWorkspace.removeValue(forKey: group.workspace.identity)
      )
    }
    let bucketOnly = bucketsByWorkspace.values
      .map { Self(workspace: $0.workspace, agents: [], bucket: $0) }
      .sorted { workspaceOrdering($0.workspace, $1.workspace) }
    sections.append(contentsOf: bucketOnly)
    return sections
  }

  private static func workspaceOrdering(
    _ lhs: DashboardAgentWorkspace,
    _ rhs: DashboardAgentWorkspace
  ) -> Bool {
    let left = "\(lhs.title)\u{0}\(lhs.subtitle)"
    let right = "\(rhs.title)\u{0}\(rhs.subtitle)"
    return left.localizedStandardCompare(right) == .orderedAscending
  }
}

private struct DashboardAgentWorkspaceHeader: View {
  let workspace: DashboardAgentWorkspace

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(workspace.title)
        .scaledFont(.caption.weight(.semibold))
      Text(workspace.subtitle)
        .scaledFont(.caption2)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(workspace.title), \(workspace.subtitle) workspace")
  }
}

private struct DashboardAgentListRow: View {
  let agent: DashboardAgentSummary
  let summary: DashboardAgentDecisionSummary?

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: agent.runtimeKind.systemImage)
        .foregroundStyle(agent.lifecycle.tint)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 2) {
        Text(agent.displayName)
          .lineLimit(1)
        Text("\(agent.runtimeKind.title) · \(agent.managedAgentID)")
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 4)

      if let summary {
        DashboardAgentDecisionBadge(summary: summary)
      }

      Circle()
        .fill(agent.lifecycle.tint)
        .frame(width: 7, height: 7)
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.dashboardAgentRow(agent.identity.selectionRawValue)
    )
    .accessibilityLabel(rowAccessibilityLabel)
    .accessibilityValue(agent.lifecycle.title)
  }

  private var rowAccessibilityLabel: String {
    let base =
      "\(agent.displayName), \(agent.runtimeKind.title), managed agent \(agent.managedAgentID)"
    guard let summary else { return base }
    return "\(base), \(summary.count) pending decisions"
  }
}

private struct DashboardWorkspaceDecisionsRow: View {
  let bucket: DashboardDecisionWorkspaceBucket

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "tray.full")
        .foregroundStyle(bucket.worstSeverity.chipColor)
        .frame(width: 16)

      Text("Workspace decisions")
        .lineLimit(1)

      Spacer(minLength: 4)

      DashboardAgentDecisionBadge(
        summary: DashboardAgentDecisionSummary(
          count: bucket.items.count,
          worstSeverity: bucket.worstSeverity
        )
      )
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Workspace decisions, \(bucket.items.count) pending")
  }
}

private struct DashboardAgentDecisionBadge: View {
  let summary: DashboardAgentDecisionSummary

  var body: some View {
    Text("\(summary.count)")
      .scaledFont(.caption2.weight(.bold))
      .monospacedDigit()
      .foregroundStyle(summary.worstSeverity.chipColor)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(summary.worstSeverity.chipColor.opacity(0.18), in: Capsule())
      .accessibilityHidden(true)
  }
}

private struct DashboardAgentsEmptyState: View {
  let title: String
  let message: String
  let systemImage: String

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      Text(message)
    }
  }
}

extension DashboardAgentRuntimeKind {
  fileprivate var systemImage: String {
    switch self {
    case .terminal: "terminal"
    case .codex: "chevron.left.forwardslash.chevron.right"
    case .acp: "network"
    }
  }
}

extension DashboardAgentLifecycle {
  fileprivate var tint: Color {
    switch self {
    case .starting: HarnessMonitorTheme.accent
    case .active: HarnessMonitorTheme.success
    case .waiting: HarnessMonitorTheme.caution
    case .idle, .completed, .stopped, .unknown: .secondary
    case .disconnected, .failed: HarnessMonitorTheme.danger
    }
  }
}
