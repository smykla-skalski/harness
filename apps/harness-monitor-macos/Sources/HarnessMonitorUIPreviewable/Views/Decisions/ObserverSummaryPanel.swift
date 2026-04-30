import HarnessMonitorKit
import SwiftUI

public struct ObserverSummaryPanel: View {
  public let scope: DecisionWorkspaceScope?
  public let observer: ObserverSummary?

  public init(
    scope: DecisionWorkspaceScope? = nil,
    observer: ObserverSummary? = nil
  ) {
    self.scope = scope
    self.observer = observer
  }

  private var facts: [InspectorFact] {
    var items: [InspectorFact] = []
    if let scope {
      items.append(.init(title: "Open decisions", value: "\(scope.totalCount)"))
      if scope.hasActiveFilters {
        items.append(.init(title: "In view", value: "\(scope.visibleCount)"))
      }
      items.append(.init(title: "Waiting on you", value: "\(scope.needsUserCount)"))
      items.append(.init(title: "Critical", value: "\(scope.criticalCount)"))
    }
    if let observer {
      items.append(.init(title: "Attention items", value: "\(observer.openIssueCount)"))
      items.append(.init(title: "Resolved", value: "\(observer.resolvedIssueCount)"))
      items.append(.init(title: "Working now", value: "\(observer.activeWorkerCount)"))
      items.append(.init(title: "Last refresh", value: formatTimestamp(observer.lastScanTime)))
    }
    return items
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Decision Desk")
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
        .accessibilityAddTraits(.isHeader)
      Text(
        scope?.resultSummary
          ?? "Stay on top of the decisions that need attention and the signals shaping them."
      )
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      if let scope, scope.hasActiveFilters {
        Text(scope.scopeDescription)
          .scaledFont(.caption.weight(.semibold))
          .harnessPillPadding()
          .harnessContentPill(tint: HarnessMonitorTheme.secondaryInk)
      }
      if !facts.isEmpty {
        InspectorFactGrid(facts: facts)
      }
      if let scope {
        if scope.visibleDecisions.isEmpty {
          InspectorSection(title: scope.emptyStateTitle) {
            Text(scope.emptyStateDescription)
              .scaledFont(.callout)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          }
        } else {
          ObserverPanelDecisionQueueSection(scope: scope)
        }
      }
      if let mutedCodes = observer?.mutedCodes, !mutedCodes.isEmpty {
        InspectorSection(title: "Muted alerts") {
          InspectorBadgeColumn(values: mutedCodes.map(humanizedWorkspaceLabel))
        }
      }
      if let openIssues = observer?.openIssues, !openIssues.isEmpty {
        ObserverPanelOpenIssuesSection(issues: openIssues)
      }
      if let activeWorkers = observer?.activeWorkers, !activeWorkers.isEmpty {
        ObserverPanelWorkersSection(workers: activeWorkers)
      }
      if let agentSessions = observer?.agentSessions, !agentSessions.isEmpty {
        InspectorSection(title: "Related sessions") {
          ObserverPanelAgentSessions(sessions: agentSessions)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(HarnessMonitorTheme.cardPadding)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.04))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.32), lineWidth: 1)
    }
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.decisionsObserverPanel,
      label: "Decision Desk",
      value: scope?.countLabel ?? "\(observer?.openIssueCount ?? 0)"
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.decisionsObserverPanel).frame")
  }
}

public struct ObserverSummaryEmptyState: View {
  public init() {}

  public var body: some View {
    VStack(spacing: HarnessMonitorTheme.spacingMD) {
      Image(systemName: "eye.slash")
        .font(.system(size: 28))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text("Signals will appear here")
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
      Text("Open alerts, muted rules, and active work appear here once the session starts reporting them.")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .multilineTextAlignment(.center)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .center)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsObserverEmptyState)
  }
}

#Preview("Observer summary panel") {
  ObserverSummaryPanel(
    scope: DecisionWorkspaceScope(
      decisions: [
        Decision(
          id: "preview-critical",
          severity: .critical,
          ruleID: "preview-rule-critical",
          sessionID: "session-leader",
          agentID: nil,
          taskID: nil,
          summary: "Leader session has stalled for 18 minutes",
          contextJSON: "{}",
          suggestedActionsJSON: "[]"
        ),
        Decision(
          id: "preview-needs-user",
          severity: .needsUser,
          ruleID: "preview-rule-needs-user",
          sessionID: "session-leader",
          agentID: nil,
          taskID: nil,
          summary: "Codex approval is waiting for operator input",
          contextJSON: "{}",
          suggestedActionsJSON: "[]"
        ),
      ],
      filters: .init(query: "", severities: [], scope: .summary)
    ),
    observer: PreviewFixtures.observer
  )
  .padding()
  .frame(width: 560)
}

#Preview("Observer empty state") {
  ObserverSummaryEmptyState()
    .padding()
    .frame(width: 560)
}

private struct ObserverPanelOpenIssuesSection: View {
  let issues: [ObserverIssueSummary]

  var body: some View {
    InspectorSection(title: "Attention signals") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        ForEach(issues) { issue in
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
              Text(humanizedWorkspaceLabel(issue.code))
                .scaledFont(.caption.bold())
              Spacer()
              Text(humanizedWorkspaceLabel(issue.severity))
                .scaledFont(.caption2.bold())
            }
            Text(issue.summary)
              .scaledFont(.subheadline)
            if let evidenceExcerpt = issue.evidenceExcerpt {
              Text(evidenceExcerpt)
                .scaledFont(.caption)
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                .lineLimit(2)
            }
          }
          .harnessCellPadding()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct ObserverPanelWorkersSection: View {
  let workers: [ObserverWorkerSummary]

  var body: some View {
    InspectorSection(title: "Working now") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        ForEach(workers) { worker in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(humanizedWorkspaceLabel(worker.agentId ?? "agent"))
                .scaledFont(.subheadline.bold())
              Spacer()
              Text(formatTimestamp(worker.startedAt))
                .scaledFont(.caption.monospaced())
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            }
            if let runtime = worker.runtime, !runtime.isEmpty {
              Text(runtimeDisplayLabel(runtime))
                .scaledFont(.caption2.weight(.semibold))
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            }
            Text("Focused on \(condensedWorkspacePath(worker.targetFile))")
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(2)
          }
          .harnessCellPadding()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct ObserverPanelAgentSessions: View {
  let sessions: [ObserverAgentSessionSummary]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      ForEach(sessions) { session in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(humanizedWorkspaceLabel(session.agentId))
              .scaledFont(.subheadline.bold())
            Spacer()
            Text(runtimeDisplayLabel(session.runtime))
              .scaledFont(.caption2.bold())
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          }
          if let lastActivity = session.lastActivity {
            Text("Last active \(formatTimestamp(lastActivity))")
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          }
        }
        .harnessCellPadding()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ObserverPanelDecisionQueueSection: View {
  let scope: DecisionWorkspaceScope

  var body: some View {
    InspectorSection(title: scope.hasActiveFilters ? "In view" : "Open decisions") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        ForEach(Array(scope.visibleDecisions.prefix(4)), id: \.id) { decision in
          ObserverPanelDecisionQueueRow(decision: decision)
        }
        if scope.visibleCount > 4 {
          Text("\(scope.visibleCount - 4) more stay in the list.")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .padding(.horizontal, HarnessMonitorTheme.spacingXS)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct ObserverPanelDecisionQueueRow: View {
  let decision: Decision

  private var severity: DecisionSeverity {
    DecisionSeverity(rawValue: decision.severityRaw) ?? .info
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Text(severity.chipLabel)
          .scaledFont(.caption.bold())
          .foregroundStyle(severity.chipColor)
        Spacer()
        Text(formatTimestamp(decision.createdAt))
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Text(decision.summary)
        .scaledFont(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
    }
    .harnessCellPadding()
  }
}
