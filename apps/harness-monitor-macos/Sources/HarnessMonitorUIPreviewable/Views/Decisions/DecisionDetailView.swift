import HarnessMonitorKit
import SwiftUI

@MainActor
/// Decisions detail column with header, suggested actions, context, audit trail, and live tick.
public struct DecisionDetailView: View {
  private enum DetailTab: String, CaseIterable, Identifiable {
    case context
    case audit

    var id: Self { self }

    var title: String {
      switch self {
      case .context:
        "Context"
      case .audit:
        "Audit Trail"
      }
    }
  }

  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  @State private var selectedTab: DetailTab = .context

  private let viewModel: DecisionDetailViewModel?
  private let auditEvents: [SupervisorEvent]
  private let liveTick: DecisionLiveTickSnapshot

  public init() {
    viewModel = nil
    auditEvents = []
    liveTick = .placeholder
  }

  public init(
    viewModel: DecisionDetailViewModel,
    auditEvents: [SupervisorEvent] = [],
    liveTick: DecisionLiveTickSnapshot = .placeholder
  ) {
    self.viewModel = viewModel
    self.auditEvents = auditEvents
    self.liveTick = liveTick
  }

  public init(
    decision: Decision,
    handler: any DecisionActionHandler = NullDecisionActionHandler(),
    auditEvents: [SupervisorEvent] = [],
    liveTick: DecisionLiveTickSnapshot = .placeholder
  ) {
    self.init(
      viewModel: DecisionDetailViewModel(decision: decision, handler: handler),
      auditEvents: auditEvents,
      liveTick: liveTick
    )
  }

  public var body: some View {
    Group {
      if let viewModel {
        populatedBody(viewModel)
          .sheet(item: snoozeBinding(for: viewModel)) { _ in
            DecisionSnoozeSheet(viewModel: viewModel)
          }
      } else {
        emptyState
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .backgroundExtensionEffect()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionDetail)
  }

  private func populatedBody(_ viewModel: DecisionDetailViewModel) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
        headerCard(viewModel)
        suggestedActions(viewModel)
        detailTabs(viewModel)
        liveTickSection
      }
      .padding(HarnessMonitorTheme.spacingLG)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "bell.badge")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text("Select a decision")
        .font(.title3)
      Text("The Monitor supervisor will surface decisions here.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding()
  }

  private func headerCard(_ viewModel: DecisionDetailViewModel) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        severityBadge(for: viewModel.severity)
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          Text(viewModel.decision.summary)
            .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
          Text(viewModel.decision.ruleID)
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        VStack(alignment: .trailing, spacing: HarnessMonitorTheme.spacingXS) {
          Text(viewModel.formattedAge(reference: .now))
            .scaledFont(.caption.bold())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Text(formatTimestamp(viewModel.decision.createdAt, configuration: dateTimeConfiguration))
            .scaledFont(.caption.monospacedDigit())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      if !viewModel.deeplinks.isEmpty {
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          ForEach(viewModel.deeplinks, id: \.stableKey) { deeplink in
            deeplinkBadge(deeplink)
          }
        }
      }
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.05))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.32), lineWidth: 1)
    }
  }

  private func suggestedActions(_ viewModel: DecisionDetailViewModel) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Suggested Actions")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if viewModel.suggestedActions.isEmpty {
        Text("No actions are available for this decision yet.")
          .scaledFont(.callout)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
          HStack(spacing: HarnessMonitorTheme.itemSpacing) {
            ForEach(viewModel.suggestedActions) { action in
              HarnessMonitorAsyncActionButton(
                title: action.title,
                tint: tint(for: action, severity: viewModel.severity),
                variant: viewModel.isPrimary(action) ? .prominent : .bordered,
                isLoading: false,
                accessibilityIdentifier: HarnessMonitorAccessibility.decisionAction(action.id)
              ) {
                await viewModel.invoke(action: action)
              }
            }
          }
        }
      }
    }
  }

  private func detailTabs(_ viewModel: DecisionDetailViewModel) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Picker("Decision detail section", selection: $selectedTab) {
        ForEach(DetailTab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)

      switch selectedTab {
      case .context:
        DecisionContextPanel(sections: viewModel.contextSections)
      case .audit:
        DecisionAuditTrailTab(events: viewModel.scopedAuditTrail(from: auditEvents))
      }
    }
  }

  private var liveTickSection: some View {
    DisclosureGroup("Live Tick") {
      DecisionsLiveTickView(snapshot: liveTick)
        .padding(.top, HarnessMonitorTheme.spacingSM)
    }
    .scaledFont(.callout)
    .accessibilityElement(children: .contain)
  }

  private func snoozeBinding(
    for viewModel: DecisionDetailViewModel
  ) -> Binding<DecisionDetailViewModel.SnoozeRequest?> {
    Binding(
      get: { viewModel.snoozeRequest },
      set: { request in
        if request == nil {
          viewModel.cancelSnooze()
        }
      }
    )
  }

  private func severityBadge(for severity: DecisionSeverity) -> some View {
    Text(severity.title)
      .scaledFont(.caption.bold())
      .foregroundStyle(severity.tint)
      .harnessPillPadding()
      .harnessControlPill(tint: severity.tint)
  }

  private func deeplinkBadge(_ deeplink: DecisionDetailViewModel.Deeplink) -> some View {
    Label {
      Text(deeplink.id)
        .scaledFont(.caption.monospaced())
    } icon: {
      Image(systemName: deeplink.kind.symbolName)
        .scaledFont(.caption.bold())
    }
    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    .harnessPillPadding()
    .harnessControlPill(tint: HarnessMonitorTheme.ink.opacity(0.6))
  }

  private func tint(for action: SuggestedAction, severity: DecisionSeverity) -> Color? {
    switch action.kind {
    case .dismiss:
      return HarnessMonitorTheme.danger
    case .snooze:
      return HarnessMonitorTheme.caution
    default:
      if severity == .critical || severity == .needsUser {
        return HarnessMonitorTheme.accent
      }
      return nil
    }
  }
}

#Preview("Decision Detail — empty") {
  DecisionDetailView()
    .frame(width: 600, height: 480)
}

#Preview("Decision Detail — populated") {
  let decision = Decision(
    id: "decision-preview",
    severity: .needsUser,
    ruleID: "stuck-agent",
    sessionID: "sess-1",
    agentID: "agent-7",
    taskID: "task-3",
    summary: "Agent has not acknowledged a critical signal."
  ,
    contextJSON:
      "{\"snapshotExcerpt\":\"agent=agent-7 idle=720s\",\"relatedTimeline\":[\"signal.sent: 12:01\",\"reminder.sent: 12:05\"],\"observerIssues\":[\"observer_idle_gap\"],\"recentActions\":[\"nudge.sent\"]}",
    suggestedActionsJSON:
      "[{\"id\":\"accept\",\"title\":\"Accept\",\"kind\":\"custom\",\"payloadJSON\":\"{}\"},{\"id\":\"snooze-1h\",\"title\":\"Snooze 1h\",\"kind\":\"snooze\",\"payloadJSON\":\"{\\\"duration\\\":3600}\"},{\"id\":\"dismiss\",\"title\":\"Dismiss\",\"kind\":\"dismiss\",\"payloadJSON\":\"{}\"}]"
  )
  decision.createdAt = Date().addingTimeInterval(-600)

  let first = SupervisorEvent(
    id: "evt-1",
    tickID: "tick-1",
    kind: "observe",
    ruleID: "stuck-agent",
    severity: nil,
    payloadJSON: "{\"summary\":\"rule observed idle gap\"}"
  )
  first.createdAt = Date().addingTimeInterval(-590)
  let second = SupervisorEvent(
    id: "evt-2",
    tickID: "tick-2",
    kind: "dispatch",
    ruleID: "stuck-agent",
    severity: .needsUser,
    payloadJSON:
      "{\"target\":{\"sessionID\":\"sess-1\",\"agentID\":\"agent-7\",\"taskID\":\"task-3\"},\"action\":\"queueDecision\"}"
  )
  second.createdAt = Date().addingTimeInterval(-560)

  return DecisionDetailView(
    decision: decision,
    auditEvents: [first, second],
    liveTick: DecisionLiveTickSnapshot(
      lastSnapshotID: "snap-42",
      tickLatencyP50Ms: 118,
      tickLatencyP95Ms: 286,
      activeObserverCount: 3,
      quarantinedRuleIDs: ["stuck-agent"]
    )
  )
  .frame(width: 700, height: 640)
}

private struct DecisionSnoozeSheet: View {
  enum SnoozeOption: String, CaseIterable, Identifiable {
    case fifteenMinutes
    case oneHour
    case fourHours
    case oneDay

    var id: Self { self }

    var title: String {
      switch self {
      case .fifteenMinutes:
        "15 minutes"
      case .oneHour:
        "1 hour"
      case .fourHours:
        "4 hours"
      case .oneDay:
        "24 hours"
      }
    }

    var duration: TimeInterval {
      switch self {
      case .fifteenMinutes:
        15 * 60
      case .oneHour:
        60 * 60
      case .fourHours:
        4 * 60 * 60
      case .oneDay:
        24 * 60 * 60
      }
    }
  }

  let viewModel: DecisionDetailViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
      Text("Snooze Decision")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
      Text("Pause this decision for a fixed interval.")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        ForEach(SnoozeOption.allCases) { option in
          HarnessMonitorAsyncActionButton(
            title: option.title,
            tint: HarnessMonitorTheme.caution,
            variant: .bordered,
            isLoading: false,
            accessibilityIdentifier: HarnessMonitorAccessibility.decisionAction(
              "snooze-\(option.rawValue)"
            ),
            fillsWidth: true
          ) {
            await viewModel.confirmSnooze(duration: option.duration)
          }
        }
      }
      Button("Cancel") {
        viewModel.cancelSnooze()
      }
      .harnessActionButtonStyle(variant: .borderless, tint: nil)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(minWidth: 320)
  }
}

private extension DecisionSeverity {
  var tint: Color {
    switch self {
    case .info:
      HarnessMonitorTheme.accent
    case .warn:
      HarnessMonitorTheme.caution
    case .needsUser:
      HarnessMonitorTheme.warmAccent
    case .critical:
      HarnessMonitorTheme.danger
    }
  }

  var title: String {
    switch self {
    case .info:
      "Info"
    case .warn:
      "Warning"
    case .needsUser:
      "Needs User"
    case .critical:
      "Critical"
    }
  }
}

private extension DecisionDetailViewModel.Deeplink.Kind {
  var symbolName: String {
    switch self {
    case .session:
      "square.stack.3d.up"
    case .agent:
      "person.crop.circle"
    case .task:
      "checklist"
    }
  }
}
