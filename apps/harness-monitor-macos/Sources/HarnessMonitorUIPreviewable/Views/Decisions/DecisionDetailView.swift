import HarnessMonitorKit
import SwiftUI

/// Which detail section the Decisions detail column renders. Lifted to the window root so the
/// principal-toolbar segmented picker and the detail body share one source of truth.
public enum DecisionDetailTab: String, CaseIterable, Identifiable {
  case context
  case audit

  public var id: Self { self }

  public var title: String {
    switch self {
    case .context:
      "Context"
    case .audit:
      "Audit Trail"
    }
  }
}

/// Decisions detail column with header, suggested actions, context, audit trail, and live tick.
@MainActor
public struct DecisionDetailView: View {
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  @Binding private var selectedTab: DecisionDetailTab

  private let viewModel: DecisionDetailViewModel?
  private let auditEvents: [SupervisorEvent]
  private let liveTick: DecisionLiveTickSnapshot

  public init(selectedTab: Binding<DecisionDetailTab> = .constant(.context)) {
    viewModel = nil
    auditEvents = []
    liveTick = .placeholder
    _selectedTab = selectedTab
  }

  public init(
    viewModel: DecisionDetailViewModel,
    auditEvents: [SupervisorEvent] = [],
    liveTick: DecisionLiveTickSnapshot = .placeholder,
    selectedTab: Binding<DecisionDetailTab> = .constant(.context)
  ) {
    self.viewModel = viewModel
    self.auditEvents = auditEvents
    self.liveTick = liveTick
    _selectedTab = selectedTab
  }

  public init(
    decision: Decision,
    handler: any DecisionActionHandler = NullDecisionActionHandler(),
    auditEvents: [SupervisorEvent] = [],
    liveTick: DecisionLiveTickSnapshot = .placeholder,
    selectedTab: Binding<DecisionDetailTab> = .constant(.context)
  ) {
    self.init(
      viewModel: DecisionDetailViewModel(decision: decision, handler: handler),
      auditEvents: auditEvents,
      liveTick: liveTick,
      selectedTab: selectedTab
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
    .toolbar {
      ToolbarItem(placement: .principal) {
        detailTabPicker
      }
    }
  }

  private var detailTabPicker: some View {
    HarnessMonitorSegmentedPicker(
      title: "Decision detail section",
      selection: $selectedTab,
      accessibilityIdentifier: HarnessMonitorAccessibility.decisionDetailTabs,
      fillsWidth: false
    ) {
      ForEach(DecisionDetailTab.allCases) { tab in
        Text(tab.title)
          .tag(tab)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.segmentedOption(
              HarnessMonitorAccessibility.decisionDetailTabs,
              option: tab.title
            )
          )
      }
    }
    .fixedSize()
  }

  private func populatedBody(_ viewModel: DecisionDetailViewModel) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
        DecisionDetailHero(
          viewModel: viewModel,
          dateTimeConfiguration: dateTimeConfiguration
        )
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
              actionButton(for: action, viewModel: viewModel)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func actionButton(
    for action: SuggestedAction,
    viewModel: DecisionDetailViewModel
  ) -> some View {
    let isPrimary = viewModel.isPrimary(action)
    let role: ButtonRole? = action.kind == .dismiss ? .destructive : nil
    let button = HarnessMonitorAsyncActionButton(
      title: action.title,
      tint: tint(for: action, severity: viewModel.severity),
      variant: isPrimary ? .prominent : .bordered,
      role: role,
      isLoading: false,
      accessibilityIdentifier: HarnessMonitorAccessibility.decisionAction(action.id)
    ) {
      await viewModel.invoke(action: action)
    }
    if isPrimary {
      button.keyboardShortcut(.defaultAction)
    } else if action.kind == .dismiss {
      button.keyboardShortcut(".", modifiers: [.command])
    } else {
      button
    }
  }

  @ViewBuilder
  private func detailTabs(_ viewModel: DecisionDetailViewModel) -> some View {
    switch selectedTab {
    case .context:
      DecisionContextPanel(sections: viewModel.contextSections)
    case .audit:
      DecisionAuditTrailTab(events: viewModel.scopedAuditTrail(from: auditEvents))
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
