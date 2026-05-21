import HarnessMonitorKit
import SwiftUI

extension DecisionDetailView {
  @ViewBuilder
  func actionButton(
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
    if let shortcut = contextAdapter.keyboardShortcut(
      for: action,
      isPrimaryFocusTarget: isPrimaryFocusTarget
    ) {
      button
        .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
    } else if isPrimaryFocusTarget && isProminentActionCandidate(action) {
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
  func detailTabs(
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
      DecisionAuditTrailTab(
        events: scopedAuditEvents,
        payloadPresentations: auditEventPayloadPresentations
      )
    }
  }

  @MainActor
  func syncScopedAuditEvents() async {
    guard let input = auditScopeInput else {
      scopedAuditInput = nil
      if !scopedAuditEvents.isEmpty {
        scopedAuditEvents = []
      }
      return
    }
    guard scopedAuditInput != input else { return }
    if !scopedAuditEvents.isEmpty {
      scopedAuditEvents = []
    }
    let output = await decisionAuditScopeWorker.scopedAuditTrail(input: input)
    guard !Task.isCancelled, auditScopeInput == input else { return }
    scopedAuditInput = input
    if scopedAuditEvents != output {
      scopedAuditEvents = output
    }
  }

  func evidenceSection(
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

  func snoozeDialogBinding(
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

  func applyPrimaryActionFocusIfNeeded() {
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

  func focusMarkerValue(for viewModel: DecisionDetailViewModel) -> String {
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
