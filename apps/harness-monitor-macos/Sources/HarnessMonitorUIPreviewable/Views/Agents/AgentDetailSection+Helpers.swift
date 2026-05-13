import HarnessMonitorKit
import SwiftUI

extension AgentDetailSection {
  nonisolated static func debouncePersist(
    value: String,
    key: String,
    defaults: UserDefaults = .standard,
    delay: Duration = .milliseconds(300)
  ) async {
    do {
      try await Task.sleep(for: delay)
    } catch {
      return
    }
    guard !Task.isCancelled else { return }
    persistDraftIfNeeded(value: value, key: key, defaults: defaults)
  }

  @discardableResult
  nonisolated static func persistDraftIfNeeded(
    value: String,
    key: String,
    defaults: UserDefaults = .standard
  ) -> Bool {
    guard defaults.string(forKey: key) != value else { return false }
    defaults.set(value, forKey: key)
    return true
  }

  static func transcriptEntries(
    store: HarnessMonitorStore,
    agent: AgentRegistration
  ) -> [TimelineEntry] {
    if agent.runtimeCapabilities.supportsNativeTranscript {
      return store.acpTranscript(forAgent: agent.agentId)
    }
    return store.timeline(forAgent: agent.agentId)
  }

  static func humanizedHookLabel(for hook: HookIntegrationDescriptor) -> String {
    let trigger: String
    switch hook.name {
    case "BeforeTool":
      trigger = "before each tool call"
    case "AfterTool":
      trigger = "after each tool call"
    case "BeforePrompt":
      trigger = "before each prompt"
    case "AfterPrompt":
      trigger = "after each prompt"
    default:
      trigger = "on \(hook.name)"
    }
    let contextMode =
      hook.supportsContextInjection ? "with context injection" : "no context"
    let contextSuffix = " (\(contextMode))"
    return "Runs \(hook.typicalLatencySeconds)s \(trigger)\(contextSuffix)"
  }

  static func draftCommandKey(agentID: String) -> String {
    "harness.workspace.agentDraft.\(agentID).command"
  }

  static func draftMessageKey(agentID: String) -> String {
    "harness.workspace.agentDraft.\(agentID).message"
  }

  static func draftActionHintKey(agentID: String) -> String {
    "harness.workspace.agentDraft.\(agentID).actionHint"
  }

  func dispatchPendingDecision(
    attention: AcpDecisionAttention,
    actionID: String
  ) {
    let decisionID = attention.oldestDecisionID
    Task {
      _ = await store.submitAcpPermissionDecisionAction(
        decisionID: decisionID,
        actionID: actionID
      )
    }
  }

  func openPendingDecisions() {
    let oldestOpenDecisionID = store.supervisorOpenDecisions
      .filter { $0.agentID == agent.agentId }
      .min {
        if $0.createdAt != $1.createdAt {
          return $0.createdAt < $1.createdAt
        }
        return $0.id < $1.id
      }?.id

    if let decisionID = oldestOpenDecisionID ?? store.selectOldestDecision(for: agent.agentId) {
      store.requestSessionDecisionRoute(decisionID: decisionID)
      store.supervisorSelectedDecisionID = decisionID
      store.requestPrimaryDecisionActionFocus(decisionID: decisionID)
      openWindow.openHarnessDecisionSession(decisionID: decisionID, store: store)
    } else {
      openWindow.openHarnessSessionWindow(sessionID: store.selectedSessionID)
    }
  }
}
