import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct SessionCreateCommands: Commands {
  let store: HarnessMonitorStore
  let windowCommandRouting: WindowCommandRoutingState

  var body: some Commands {
    let createAgent = createAction(for: .agent)
    let createCodexAgent = createCodexAction
    let createOpenRouterAgent = createOpenRouterAction
    let createTask = createAction(for: .task)
    let createDecision = createAction(for: .decision)
    CommandGroup(after: .newItem) {
      Button("New Agent") { createAgent?() }
        .keyboardShortcut(
          SessionCreateKind.agent.createShortcut.keyEquivalent,
          modifiers: SessionCreateKind.agent.createShortcut.requiredEventModifiers
        )
        .disabled(createAgent == nil)
      Button("New Codex Agent") { createCodexAgent?() }
        .disabled(createCodexAgent == nil)
      Button("New OpenRouter Session") { createOpenRouterAgent?() }
        .disabled(createOpenRouterAgent == nil)
      Button("New Task") { createTask?() }
        .keyboardShortcut(
          SessionCreateKind.task.createShortcut.keyEquivalent,
          modifiers: SessionCreateKind.task.createShortcut.requiredEventModifiers
        )
        .disabled(createTask == nil)
      Button("New Decision") { createDecision?() }
        .keyboardShortcut(
          SessionCreateKind.decision.createShortcut.keyEquivalent,
          modifiers: SessionCreateKind.decision.createShortcut.requiredEventModifiers
        )
        .disabled(createDecision == nil)
    }
  }

  private var activeSessionID: String? {
    guard windowCommandRouting.activeScope == .session else {
      return nil
    }
    return windowCommandRouting.activeSessionID
  }

  private var createCodexAction: (() -> Void)? {
    guard let sessionID = activeSessionID else {
      return nil
    }
    return { store.presentedSheet = .newCodexAgent(sessionID: sessionID) }
  }

  private var createOpenRouterAction: (() -> Void)? {
    guard let sessionID = activeSessionID else {
      return nil
    }
    return { store.presentedSheet = .newOpenRouterAgent(sessionID: sessionID) }
  }

  private func createAction(for kind: SessionCreateKind) -> (() -> Void)? {
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
