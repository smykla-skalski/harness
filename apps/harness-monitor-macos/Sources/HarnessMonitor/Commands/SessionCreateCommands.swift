import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct SessionCreateCommands: Commands {
  let store: HarnessMonitorStore
  let windowCommandRouting: WindowCommandRoutingState
  let sessionCreate: SessionCreateContext?

  static func shouldShowExplicitCommand(
    for kind: SessionCreateKind,
    primaryKind: SessionCreateKind?
  ) -> Bool {
    primaryKind != kind
  }

  var body: some Commands {
    let primaryKind = sessionCreate?.primaryKind
    let createAgent = createAction(for: .agent)
    let createCodexAgent = createCodexAction
    let createTask = createAction(for: .task)
    let createDecision = createAction(for: .decision)
    CommandGroup(after: .newItem) {
      if Self.shouldShowExplicitCommand(for: .agent, primaryKind: primaryKind) {
        Button("New Agent") { createAgent?() }
          .keyboardShortcut(
            SessionCreateKind.agent.createShortcut.keyEquivalent,
            modifiers: SessionCreateKind.agent.createShortcut.requiredEventModifiers
          )
          .disabled(createAgent == nil)
      }
      Button("New Codex Agent") { createCodexAgent?() }
        .disabled(createCodexAgent == nil)
      if Self.shouldShowExplicitCommand(for: .task, primaryKind: primaryKind) {
        Button("New Task") { createTask?() }
          .keyboardShortcut(
            SessionCreateKind.task.createShortcut.keyEquivalent,
            modifiers: SessionCreateKind.task.createShortcut.requiredEventModifiers
          )
          .disabled(createTask == nil)
      }
      if Self.shouldShowExplicitCommand(for: .decision, primaryKind: primaryKind) {
        Button("New Decision") { createDecision?() }
          .keyboardShortcut(
            SessionCreateKind.decision.createShortcut.keyEquivalent,
            modifiers: SessionCreateKind.decision.createShortcut.requiredEventModifiers
          )
          .disabled(createDecision == nil)
      }
    }
  }

  private var activeSessionID: String? {
    guard windowCommandRouting.activeScope == .session else {
      return nil
    }
    return windowCommandRouting.activeSessionID
  }

  private var createCodexAction: (() -> Void)? {
    if let createCodexAgent = sessionCreate?.createCodexAgent {
      return createCodexAgent
    }
    guard let sessionID = activeSessionID else {
      return nil
    }
    return { store.presentedSheet = .newCodexAgent(sessionID: sessionID) }
  }

  private func createAction(for kind: SessionCreateKind) -> (() -> Void)? {
    switch kind {
    case .agent:
      if let createAgent = sessionCreate?.createAgent {
        return createAgent
      }
    case .task:
      if let createTask = sessionCreate?.createTask {
        return createTask
      }
    case .decision:
      if let createDecision = sessionCreate?.createDecision {
        return createDecision
      }
    }
    guard let sessionID = activeSessionID else {
      return nil
    }
    return {
      store.requestSessionRouteCreate(kind.routeCreateEntryPoint, sessionID: sessionID)
    }
  }
}

extension SessionCreateKind {
  fileprivate var routeCreateEntryPoint: SessionRouteCreateEntryPoint {
    switch self {
    case .agent:
      return .agent
    case .task:
      return .task
    case .decision:
      return .decision
    }
  }
}
