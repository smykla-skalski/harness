import HarnessMonitorKit
import SwiftUI

let decisionAuditScopeWorker = DecisionAuditScopeWorker()

/// Decisions detail column with header, suggested actions, context, audit trail, and live tick.
public struct DecisionDetailView: View {
  @Environment(\.harnessDateTimeConfiguration)
  var dateTimeConfiguration

  @Binding var selectedTab: DecisionDetailTab
  @AccessibilityFocusState var focusedPrimaryActionDecisionID: String?
  @FocusState var keyboardFocusedPrimaryActionDecisionID: String?
  @State private var handledPrimaryActionFocusTick = 0
  @State private var scopedAuditEvents: [SupervisorEventSnapshot] = []
  @State private var scopedAuditInput: DecisionDetailViewModel.AuditScopeInput?

  let viewModel: DecisionDetailViewModel?
  let store: HarnessMonitorStore?
  let auditEvents: [SupervisorEventSnapshot]
  let auditEventPayloadPresentations: [String: DecisionAuditTrailPayloadPresentation]
  let observer: ObserverSummary?
  let decisionScope: DecisionWorkspaceScope?
  let primaryActionFocusDecisionID: String?
  let primaryActionFocusRequestTick: Int

  public init(
    selectedTab: Binding<DecisionDetailTab> = .constant(.context),
    observer: ObserverSummary? = nil,
    decisionScope: DecisionWorkspaceScope? = nil,
    primaryActionFocusDecisionID: String? = nil,
    primaryActionFocusRequestTick: Int = 0
  ) {
    viewModel = nil
    store = nil
    auditEvents = []
    auditEventPayloadPresentations = [:]
    self.observer = observer
    self.decisionScope = decisionScope
    self.primaryActionFocusDecisionID = primaryActionFocusDecisionID
    self.primaryActionFocusRequestTick = primaryActionFocusRequestTick
    _selectedTab = selectedTab
  }

  // Optional viewModel form keeps tree identity stable when selection flips nil/non-nil.
  public init(
    viewModel: DecisionDetailViewModel?,
    store: HarnessMonitorStore? = nil,
    auditEvents: [SupervisorEventSnapshot] = [],
    selectedTab: Binding<DecisionDetailTab> = .constant(.context),
    observer: ObserverSummary? = nil,
    decisionScope: DecisionWorkspaceScope? = nil,
    primaryActionFocusDecisionID: String? = nil,
    primaryActionFocusRequestTick: Int = 0
  ) {
    self.init(
      viewModel: viewModel,
      store: store,
      auditEvents: auditEvents,
      auditEventPayloadPresentations: [:],
      selectedTab: selectedTab,
      observer: observer,
      decisionScope: decisionScope,
      primaryActionFocusDecisionID: primaryActionFocusDecisionID,
      primaryActionFocusRequestTick: primaryActionFocusRequestTick
    )
  }

  init(
    viewModel: DecisionDetailViewModel?,
    store: HarnessMonitorStore? = nil,
    auditEvents: [SupervisorEventSnapshot] = [],
    auditEventPayloadPresentations: [String: DecisionAuditTrailPayloadPresentation] = [:],
    selectedTab: Binding<DecisionDetailTab> = .constant(.context),
    observer: ObserverSummary? = nil,
    decisionScope: DecisionWorkspaceScope? = nil,
    primaryActionFocusDecisionID: String? = nil,
    primaryActionFocusRequestTick: Int = 0
  ) {
    self.viewModel = viewModel
    self.store = store
    self.auditEvents = auditEvents
    self.auditEventPayloadPresentations = auditEventPayloadPresentations
    self.observer = observer
    self.decisionScope = decisionScope
    self.primaryActionFocusDecisionID = primaryActionFocusDecisionID
    self.primaryActionFocusRequestTick = primaryActionFocusRequestTick
    _selectedTab = selectedTab
  }

  // Optional-decision entry point avoids conditional tree churn across nil flips.
  public init(
    decision: Decision?,
    store: HarnessMonitorStore? = nil,
    handler: any DecisionActionHandler = NullDecisionActionHandler(),
    auditEvents: [SupervisorEventSnapshot] = [],
    selectedTab: Binding<DecisionDetailTab> = .constant(.context),
    observer: ObserverSummary? = nil,
    decisionScope: DecisionWorkspaceScope? = nil,
    primaryActionFocusDecisionID: String? = nil,
    primaryActionFocusRequestTick: Int = 0
  ) {
    if let decision {
      self.init(
        viewModel: DecisionDetailViewModel(decision: decision, handler: handler),
        store: store,
        auditEvents: auditEvents,
        auditEventPayloadPresentations: [:],
        selectedTab: selectedTab,
        observer: observer,
        decisionScope: decisionScope,
        primaryActionFocusDecisionID: primaryActionFocusDecisionID,
        primaryActionFocusRequestTick: primaryActionFocusRequestTick
      )
    } else {
      self.init(
        selectedTab: selectedTab,
        observer: observer,
        decisionScope: decisionScope,
        primaryActionFocusDecisionID: primaryActionFocusDecisionID,
        primaryActionFocusRequestTick: primaryActionFocusRequestTick
      )
    }
  }

  init(
    decision: Decision?,
    store: HarnessMonitorStore? = nil,
    handler: any DecisionActionHandler = NullDecisionActionHandler(),
    auditEvents: [SupervisorEventSnapshot] = [],
    auditEventPayloadPresentations: [String: DecisionAuditTrailPayloadPresentation],
    selectedTab: Binding<DecisionDetailTab> = .constant(.context),
    observer: ObserverSummary? = nil,
    decisionScope: DecisionWorkspaceScope? = nil,
    primaryActionFocusDecisionID: String? = nil,
    primaryActionFocusRequestTick: Int = 0
  ) {
    if let decision {
      self.init(
        viewModel: DecisionDetailViewModel(decision: decision, handler: handler),
        store: store,
        auditEvents: auditEvents,
        auditEventPayloadPresentations: auditEventPayloadPresentations,
        selectedTab: selectedTab,
        observer: observer,
        decisionScope: decisionScope,
        primaryActionFocusDecisionID: primaryActionFocusDecisionID,
        primaryActionFocusRequestTick: primaryActionFocusRequestTick
      )
    } else {
      self.init(
        selectedTab: selectedTab,
        observer: observer,
        decisionScope: decisionScope,
        primaryActionFocusDecisionID: primaryActionFocusDecisionID,
        primaryActionFocusRequestTick: primaryActionFocusRequestTick
      )
    }
  }

  public var body: some View {
    // The owning scroll column already applies the top scroll-edge effect.
    detailBody
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.decisionDetail)
      .overlay {
        if let viewModel {
          AccessibilityTextMarker(
            identifier: HarnessMonitorAccessibility.decisionPrimaryActionFocusState,
            text: focusMarkerValue(for: viewModel)
          )
        }
      }
      .onAppear(perform: applyPrimaryActionFocusIfNeeded)
      .onChange(of: primaryActionFocusRequestTick) { _, _ in
        applyPrimaryActionFocusIfNeeded()
      }
      .task(id: auditScopeInput) {
        await syncScopedAuditEvents()
      }
  }

  var auditScopeInput: DecisionDetailViewModel.AuditScopeInput? {
    guard let viewModel else { return nil }
    return DecisionDetailViewModel.AuditScopeInput(
      decision: viewModel.decision,
      events: auditEvents
    )
  }

  @ViewBuilder var detailBody: some View {
    if let viewModel {
      populatedBody(viewModel)
        .confirmationDialog(
          "Snooze Decision",
          isPresented: snoozeDialogBinding(for: viewModel),
          titleVisibility: .visible
        ) {
          ForEach(SnoozeOption.allCases) { option in
            Button(option.actionTitle) {
              Task {
                await viewModel.confirmSnooze(duration: option.duration)
              }
            }
          }
          Button("Cancel", role: .cancel) {
            viewModel.cancelSnooze()
          }
        } message: {
          Text("Pause this decision for a fixed interval")
        }
    } else {
      emptyState
    }
  }

  var detailTabPicker: some View {
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

  func populatedBody(_ viewModel: DecisionDetailViewModel) -> some View {
    let contextAdapter = DecisionKindContextAdapter(
      decision: viewModel.decision,
      store: store
    )
    return ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
        DecisionDetailHero(
          viewModel: viewModel,
          dateTimeConfiguration: dateTimeConfiguration
        )
        suggestedActions(viewModel, contextAdapter: contextAdapter)
        DecisionRelatedAgentContextSection(
          decision: viewModel.decision,
          store: store
        )
        evidenceSection(
          viewModel,
          contextAdapter: contextAdapter
        )
      }
      .padding(HarnessMonitorTheme.spacingLG)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .harnessPrimaryContentScrollSurface(
      listIdentifier: HarnessMonitorAccessibility.decisionDetailScrollView,
      listLabel: "Decision detail"
    )
  }

  @ViewBuilder var emptyState: some View {
    if decisionScope != nil || observer != nil {
      ScrollView {
        ObserverSummaryPanel(scope: decisionScope, observer: observer)
          .padding(HarnessMonitorTheme.spacingLG)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .harnessPrimaryContentScrollSurface(
        listIdentifier: HarnessMonitorAccessibility.decisionDetailScrollView,
        listLabel: "Decision detail"
      )
    } else {
      VStack(spacing: 12) {
        Image(systemName: "bell.badge")
          .font(.largeTitle)
          .foregroundStyle(.secondary)
        Text("Select a decision")
          .font(.title3)
        Text("Decisions and related activity appear here")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding()
    }
  }

}
