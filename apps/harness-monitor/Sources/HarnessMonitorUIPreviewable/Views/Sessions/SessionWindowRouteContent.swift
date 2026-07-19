import HarnessMonitorKit
import SwiftUI

struct SessionWindowOverview: View {
  let store: HarnessMonitorStore
  let snapshot: HarnessMonitorSessionWindowSnapshot
  let decisions: [Decision]
  let tuiStatusByAgent: [String: AgentTuiStatus]
  @Environment(\.fontScale)
  var fontScale
  @State private var taskBoardSnapshot = TaskBoardInboxSnapshot(
    generatedAt: nil,
    isFromCache: true
  )

  var metrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  var runtimePresentation: HarnessMonitorStore.AgentRuntimePresentationContext? {
    switch snapshot.source {
    case .live:
      return HarnessMonitorStore.AgentRuntimePresentationContext(
        availability: .live,
        acpSnapshots: snapshot.acpAgents,
        acpInspectSample: snapshot.acpInspectSample
      )
    case .cache:
      return HarnessMonitorStore.AgentRuntimePresentationContext(availability: .persisted)
    case .catalog:
      return nil
    }
  }

  var body: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: metrics.contentPadding,
      verticalPadding: metrics.contentPadding,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.sessionCockpitScrollView,
      scrollSurfaceLabel: "Session overview"
    ) {
      VStack(alignment: .leading, spacing: metrics.overviewSpacing) {
        SessionOverviewInfoStrip(facts: overviewFacts, metrics: metrics)
        TaskBoardOverviewHost(
          scope: .session(sessionID: snapshot.summary.sessionId),
          store: store,
          snapshot: taskBoardSnapshot,
          taskBoardItems: taskBoardSourceItems,
          decisions: decisions,
          orchestratorStatus: store.contentUI.dashboard.taskBoardOrchestratorStatus,
          evaluationSummary: store.contentUI.dashboard.taskBoardEvaluationSummary,
          isActionInFlight: store.contentUI.dashboard.isTaskBoardBusy
            || store.contentUI.dashboard.connectionState != .online,
          showsOperationsPanel: false
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task(id: taskBoardSnapshotKey) {
      taskBoardSnapshot = makeTaskBoardSnapshot()
    }
  }

  var overviewFacts: [SessionOverviewFact] {
    [
      SessionOverviewFact(title: "Status", value: snapshot.summary.status.title),
      SessionOverviewFact(title: "Project", value: snapshot.summary.projectName),
      SessionOverviewFact(title: "Worktree", value: snapshot.summary.worktreeDisplayName),
      SessionOverviewFact(
        title: "Agents",
        value: agentCountText,
        usesMonospacedDigits: true
      ),
      SessionOverviewFact(
        title: "Open Tasks",
        value: "\(snapshot.summary.metrics.openTaskCount)",
        usesMonospacedDigits: true
      ),
      SessionOverviewFact(title: "Source", value: snapshot.source.rawValue),
    ]
  }

  var agentCount: Int {
    snapshot.detail?.agents.count ?? snapshot.summary.metrics.agentCount
  }

  var agentCountText: String {
    guard
      runtimePresentation?.availability == .live,
      let detail = snapshot.detail
    else {
      return "\(agentCount)"
    }

    let summary = store.agentRuntimeSummary(
      sessionID: snapshot.summary.sessionId,
      sessionRegistrations: detail.agents,
      tuiStatusByAgent: tuiStatusByAgent,
      runtimePresentation: runtimePresentation
    )
    guard summary.registeredCount > 0 else {
      return "0"
    }
    guard summary.activeCount != summary.registeredCount else {
      return "\(summary.activeCount) active"
    }
    return "\(summary.activeCount) active of \(summary.registeredCount)"
  }

}

struct SessionOverviewFact: Identifiable {
  let title: String
  let value: String
  let usesMonospacedDigits: Bool
  var id: String { title }

  init(
    title: String,
    value: String,
    usesMonospacedDigits: Bool = false
  ) {
    self.title = title
    self.value = value
    self.usesMonospacedDigits = usesMonospacedDigits
  }
}

struct SessionOverviewInfoStrip: View {
  let facts: [SessionOverviewFact]
  let metrics: SessionWindowRouteContentMetrics

  var body: some View {
    ViewThatFits(in: .horizontal) {
      cardsRow(expandsToFill: true)
      ScrollView(.horizontal, showsIndicators: true) {
        cardsRow(expandsToFill: false)
          .padding(.vertical, 1)
      }
      .scrollClipDisabled()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  func cardsRow(expandsToFill: Bool) -> some View {
    HStack(alignment: .top, spacing: metrics.gridVerticalSpacing) {
      ForEach(facts) { fact in
        SessionOverviewFactCard(fact: fact, metrics: metrics)
          .frame(
            minWidth: metrics.overviewCardMinWidth,
            maxWidth: expandsToFill ? .infinity : nil,
            alignment: .leading
          )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct SessionOverviewFactCard: View {
  let fact: SessionOverviewFact
  let metrics: SessionWindowRouteContentMetrics
  @Environment(\.fontScale)
  var fontScale

  var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.bold), by: fontScale)
  }

  var valueFont: Font {
    HarnessMonitorTextSize.scaledFont(
      .system(.title3, design: .rounded, weight: .semibold),
      by: fontScale
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.overviewCardTextSpacing) {
      Text(fact.title.uppercased())
        .font(titleFont)
        .tracking(HarnessMonitorTheme.uppercaseTracking)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      valueView
        .font(valueFont)
        .foregroundStyle(HarnessMonitorTheme.ink)
        .textSelection(.enabled)
        .multilineTextAlignment(.leading)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(
      maxWidth: .infinity,
      minHeight: metrics.overviewCardMinHeight,
      alignment: .leading
    )
    .padding(HarnessMonitorTheme.cardPadding)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.04))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.32), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(fact.title)
    .accessibilityValue(fact.value)
  }

  @ViewBuilder var valueView: some View {
    if fact.usesMonospacedDigits {
      Text(verbatim: fact.value)
        .monospacedDigit()
    } else {
      Text(verbatim: fact.value)
    }
  }
}
