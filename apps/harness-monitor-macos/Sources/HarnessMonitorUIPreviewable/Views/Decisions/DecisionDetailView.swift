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
  @AccessibilityFocusState private var focusedPrimaryActionDecisionID: String?
  @FocusState private var keyboardFocusedPrimaryActionDecisionID: String?
  @State private var handledPrimaryActionFocusTick = 0

  private let viewModel: DecisionDetailViewModel?
  private let store: HarnessMonitorStore?
  private let auditEvents: [SupervisorEvent]
  private let observer: ObserverSummary?
  private let decisionScope: DecisionWorkspaceScope?
  private let primaryActionFocusDecisionID: String?
  private let primaryActionFocusRequestTick: Int

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
    self.observer = observer
    self.decisionScope = decisionScope
    self.primaryActionFocusDecisionID = primaryActionFocusDecisionID
    self.primaryActionFocusRequestTick = primaryActionFocusRequestTick
    _selectedTab = selectedTab
  }

  public init(
    viewModel: DecisionDetailViewModel,
    store: HarnessMonitorStore? = nil,
    auditEvents: [SupervisorEvent] = [],
    selectedTab: Binding<DecisionDetailTab> = .constant(.context),
    observer: ObserverSummary? = nil,
    decisionScope: DecisionWorkspaceScope? = nil,
    primaryActionFocusDecisionID: String? = nil,
    primaryActionFocusRequestTick: Int = 0
  ) {
    self.viewModel = viewModel
    self.store = store
    self.auditEvents = auditEvents
    self.observer = observer
    self.decisionScope = decisionScope
    self.primaryActionFocusDecisionID = primaryActionFocusDecisionID
    self.primaryActionFocusRequestTick = primaryActionFocusRequestTick
    _selectedTab = selectedTab
  }

  public init(
    decision: Decision,
    store: HarnessMonitorStore? = nil,
    handler: any DecisionActionHandler = NullDecisionActionHandler(),
    auditEvents: [SupervisorEvent] = [],
    selectedTab: Binding<DecisionDetailTab> = .constant(.context),
    observer: ObserverSummary? = nil,
    decisionScope: DecisionWorkspaceScope? = nil,
    primaryActionFocusDecisionID: String? = nil,
    primaryActionFocusRequestTick: Int = 0
  ) {
    self.init(
      viewModel: DecisionDetailViewModel(decision: decision, handler: handler),
      store: store,
      auditEvents: auditEvents,
      selectedTab: selectedTab,
      observer: observer,
      decisionScope: decisionScope,
      primaryActionFocusDecisionID: primaryActionFocusDecisionID,
      primaryActionFocusRequestTick: primaryActionFocusRequestTick
    )
  }

  public var body: some View {
    detailBody
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .backgroundExtensionEffect()
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
      .onAppear {
        applyPrimaryActionFocusIfNeeded()
      }
      .onChange(of: primaryActionFocusRequestTick) { _, _ in
        applyPrimaryActionFocusIfNeeded()
      }
  }

  @ViewBuilder private var detailBody: some View {
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
          Text("Pause this decision for a fixed interval.")
        }
    } else {
      emptyState
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
  }

  @ViewBuilder private var emptyState: some View {
    if decisionScope != nil || observer != nil {
      ScrollView {
        ObserverSummaryPanel(scope: decisionScope, observer: observer)
          .padding(HarnessMonitorTheme.spacingLG)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      VStack(spacing: 12) {
        Image(systemName: "bell.badge")
          .font(.largeTitle)
          .foregroundStyle(.secondary)
        Text("Select a decision")
          .font(.title3)
        Text("Decisions and related activity appear here.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding()
    }
  }

  private func suggestedActions(
    _ viewModel: DecisionDetailViewModel,
    contextAdapter: DecisionKindContextAdapter
  ) -> some View {
    let effectiveActions = contextAdapter.suggestedActions(from: viewModel.suggestedActions)
    let primaryActionID = primaryActionID(for: effectiveActions)
    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Suggested Actions")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if effectiveActions.isEmpty {
        Text("No actions are available for this decision yet.")
          .scaledFont(.callout)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        actionButtonGroup(
          actions: effectiveActions,
          primaryActionID: primaryActionID,
          viewModel: viewModel,
          contextAdapter: contextAdapter
        )
      }
    }
  }

  @ViewBuilder
  private func actionButtonGroup(
    actions: [SuggestedAction],
    primaryActionID: String?,
    viewModel: DecisionDetailViewModel,
    contextAdapter: DecisionKindContextAdapter
  ) -> some View {
    let emphasizedPrimaryActionID =
      primaryActionID.flatMap { candidateID in
        actions.first { $0.id == candidateID && isProminentActionCandidate($0) }?.id
      }
    let wrappedActions = actions.filter { $0.id != emphasizedPrimaryActionID }

    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      if let emphasizedPrimaryActionID,
        let primaryAction = actions.first(where: { $0.id == emphasizedPrimaryActionID })
      {
        actionButton(
          for: primaryAction,
          viewModel: viewModel,
          contextAdapter: contextAdapter,
          isPrimaryFocusTarget: primaryActionID == emphasizedPrimaryActionID,
          emphasizesAction: true,
          fillsWidth: true
        )
      }
      if !wrappedActions.isEmpty {
        HarnessMonitorWrapLayout(
          spacing: HarnessMonitorTheme.itemSpacing,
          lineSpacing: HarnessMonitorTheme.spacingXS
        ) {
          ForEach(wrappedActions) { action in
            actionButton(
              for: action,
              viewModel: viewModel,
              contextAdapter: contextAdapter,
              isPrimaryFocusTarget: action.id == primaryActionID,
              emphasizesAction: false
            )
          }
        }
      }
    }
  }

  @ViewBuilder
  private func actionButton(
    for action: SuggestedAction,
    viewModel: DecisionDetailViewModel,
    contextAdapter: DecisionKindContextAdapter,
    isPrimaryFocusTarget: Bool,
    emphasizesAction: Bool,
    fillsWidth: Bool = false
  ) -> some View {
    let role: ButtonRole? = action.kind == .dismiss ? .destructive : nil
    let button = HarnessMonitorAsyncActionButton(
      title: action.title,
      tint: tint(for: action, severity: viewModel.severity),
      variant:
        emphasizesAction && !contextAdapter.prefersSubtlePrimaryAction
        ? .prominent
        : .bordered,
      role: role,
      isLoading: false,
      accessibilityIdentifier: HarnessMonitorAccessibility.decisionAction(action.id),
      fillsWidth: fillsWidth,
      accessibilityFocusBinding: isPrimaryFocusTarget ? $focusedPrimaryActionDecisionID : nil,
      accessibilityFocusValue: isPrimaryFocusTarget ? viewModel.decision.id : nil,
      keyboardFocusBinding: isPrimaryFocusTarget ? $keyboardFocusedPrimaryActionDecisionID : nil,
      keyboardFocusValue: isPrimaryFocusTarget ? viewModel.decision.id : nil
    ) {
      await viewModel.invoke(action: action)
    }
    .disabled(contextAdapter.isActionDisabled(action.id))
    if isPrimaryFocusTarget && isProminentActionCandidate(action) {
      button
        .keyboardShortcut(.defaultAction)
    } else if action.kind == .dismiss {
      button
        .keyboardShortcut(".", modifiers: [.command])
    } else {
      button
    }
  }

  @ViewBuilder
  private func detailTabs(
    _ viewModel: DecisionDetailViewModel,
    contextAdapter: DecisionKindContextAdapter
  ) -> some View {
    switch selectedTab {
    case .context:
      DecisionKindContextView(
        adapter: contextAdapter,
        contextSections: viewModel.contextSections
      )
    case .audit:
      DecisionAuditTrailTab(events: viewModel.scopedAuditTrail(from: auditEvents))
    }
  }

  private func evidenceSection(
    _ viewModel: DecisionDetailViewModel,
    contextAdapter: DecisionKindContextAdapter
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Evidence")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityAddTraits(.isHeader)
      detailTabPicker
        .frame(maxWidth: .infinity, alignment: .leading)
      detailTabs(viewModel, contextAdapter: contextAdapter)
    }
  }

  private func snoozeDialogBinding(
    for viewModel: DecisionDetailViewModel
  ) -> Binding<Bool> {
    Binding(
      get: { viewModel.snoozeRequest != nil },
      set: { isPresented in
        if !isPresented {
          viewModel.cancelSnooze()
        }
      }
    )
  }

  private func applyPrimaryActionFocusIfNeeded() {
    guard
      let viewModel,
      primaryActionFocusDecisionID == viewModel.decision.id,
      primaryActionFocusRequestTick != 0,
      primaryActionFocusRequestTick != handledPrimaryActionFocusTick,
      primaryActionID(
        for: DecisionKindContextAdapter(
          decision: viewModel.decision,
          store: store
        )
        .suggestedActions(from: viewModel.suggestedActions)
      ) != nil
    else {
      return
    }
    handledPrimaryActionFocusTick = primaryActionFocusRequestTick
    selectedTab = .context
    focusedPrimaryActionDecisionID = nil
    keyboardFocusedPrimaryActionDecisionID = nil
    let decisionID = viewModel.decision.id
    Task { @MainActor in
      for _ in 0..<4 {
        await Task.yield()
        keyboardFocusedPrimaryActionDecisionID = decisionID
        focusedPrimaryActionDecisionID = decisionID
        try? await Task.sleep(nanoseconds: 50_000_000)
        if focusedPrimaryActionDecisionID == decisionID
          || keyboardFocusedPrimaryActionDecisionID == decisionID
        {
          return
        }
      }
    }
  }

  private func focusMarkerValue(for viewModel: DecisionDetailViewModel) -> String {
    let isAccessibilityFocused = focusedPrimaryActionDecisionID == viewModel.decision.id
    let isKeyboardFocused = keyboardFocusedPrimaryActionDecisionID == viewModel.decision.id
    return [
      "decision=\(viewModel.decision.id)",
      "focused=\(isAccessibilityFocused || isKeyboardFocused)",
      "accessibilityFocused=\(isAccessibilityFocused)",
      "keyboardFocused=\(isKeyboardFocused)",
      "tick=\(handledPrimaryActionFocusTick)",
    ].joined(separator: " ")
  }
}
