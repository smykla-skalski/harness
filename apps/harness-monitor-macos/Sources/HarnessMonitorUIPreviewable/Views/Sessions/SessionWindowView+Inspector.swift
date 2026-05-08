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
      createTask: { cache.selectCreate(.task) },
      createDecision: { cache.selectCreate(.decision) }
    )
  }

  var primaryCreateKind: SessionCreateKind {
    switch stateCache.selection {
    case .agent: .agent
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
    guard abs(detailColumnWidth - width) > 0.5 else { return }
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
