import SwiftUI

extension SessionWindowView {
  var navigationCommand: SessionNavigationCommand {
    let cache = stateCache
    return SessionNavigationCommand(
      sessionID: token.sessionID,
      canGoBack: stateCache.navigationHistory.canGoBack,
      canGoForward: stateCache.navigationHistory.canGoForward,
      goBack: { cache.navigateBack() },
      goForward: { cache.navigateForward() }
    )
  }

  var attentionFocus: SessionAttentionFocus {
    SessionAttentionFocus(
      sessionID: token.sessionID,
      pendingDecisionCount: matchingDecisions.count
    )
  }

  var inspectorCommand: SessionInspectorCommand {
    let visibleBinding = $inspectorVisible
    let preferredBinding = $inspectorPreferred
    return SessionInspectorCommand(
      sessionID: token.sessionID,
      isVisible: visibleBinding.wrappedValue && canPresentInspector,
      toggle: {
        setInspectorPreference(
          !preferredBinding.wrappedValue,
          visibleBinding: visibleBinding,
          preferredBinding: preferredBinding
        )
      }
    )
  }

  var decisionCommand: SessionDecisionCommand {
    SessionDecisionCommandFactory.make(
      store: store,
      state: stateCache,
      visibleDecisions: matchingDecisions,
      undoManager: undoManager
    )
  }

  var createContext: SessionCreateContext {
    let cache = stateCache
    return SessionCreateContext(
      sessionID: token.sessionID,
      primaryKind: primaryCreateKind,
      createAgent: { cache.selectCreate(.agent) },
      createCodexAgent: { store.presentedSheet = .newCodexAgent(sessionID: token.sessionID) },
      createTask: { cache.selectCreate(.task) },
      createDecision: { cache.selectCreate(.decision) }
    )
  }

  var primaryCreateKind: SessionCreateKind {
    switch stateCache.selection {
    case .agent: .agent
    case .codexRun: .agent
    case .task: .task
    case .decision: .decision
    case .create(let draft): draft.kind
    case .route(let route):
      switch route {
      case .tasks: .task
      case .decisions: .decision
      case .agents, .overview, .timeline, .terminal: .agent
      }
    }
  }

  func updateDetailColumnWidth(
    _ width: CGFloat,
    visibleBinding: Binding<Bool>,
    preferredBinding: Binding<Bool>,
    announce: Bool = true
  ) {
    // Only commit width changes that flip canPresentInspector. Continuous
    // geometry updates during the NSP sidebar reveal otherwise churn
    // focusedSceneValue(\.sessionInspector, …), which propagates through
    // FocusedValues into OutlineListRepresentable.update mid-animation
    // and snaps the spring.
    let previousAllows =
      detailColumnWidth > 0
      && SessionInspectorVisibilityPolicy.allowsInspector(width: detailColumnWidth)
    let nextAllows =
      width > 0
      && SessionInspectorVisibilityPolicy.allowsInspector(width: width)
    guard previousAllows != nextAllows || detailColumnWidth == 0 else { return }
    detailColumnWidth = width
    reconcileInspectorVisibility(
      visibleBinding: visibleBinding,
      preferredBinding: preferredBinding,
      announce: announce
    )
  }

  func reconcileInspectorVisibility(
    visibleBinding: Binding<Bool>,
    preferredBinding: Binding<Bool>,
    announce: Bool = true
  ) {
    setInspectorVisibility(
      SessionInspectorVisibilityPolicy.resolvedVisible(
        preferredVisible: preferredBinding.wrappedValue,
        canPresent: canPresentInspector
      ),
      binding: visibleBinding,
      announce: announce
    )
  }

  func setInspectorPreference(
    _ preferredVisible: Bool,
    visibleBinding: Binding<Bool>,
    preferredBinding: Binding<Bool>,
    announce: Bool = true
  ) {
    guard preferredBinding.wrappedValue != preferredVisible
      || visibleBinding.wrappedValue != preferredVisible
    else { return }
    preferredBinding.wrappedValue = preferredVisible
    reconcileInspectorVisibility(
      visibleBinding: visibleBinding,
      preferredBinding: preferredBinding,
      announce: announce
    )
  }

  func setInspectorVisibility(
    _ visible: Bool,
    binding: Binding<Bool>,
    announce: Bool = true
  ) {
    guard binding.wrappedValue != visible else { return }
    binding.wrappedValue = visible
    if announce {
      SessionInspectorAnnouncer.announce(visible: visible)
    }
  }
}
