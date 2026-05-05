import Foundation
import HarnessMonitorKit

enum WorkspaceSelectionDefaults {
  static let selectionKey = "HarnessMonitor.Workspace.selection"

  private static let uiTestsEnvironmentKey = "HARNESS_MONITOR_UI_TESTS"

  private static var defaults: UserDefaults {
    UserDefaults.standard
  }

  private static var scopedSelectionKey: String {
    guard ProcessInfo.processInfo.environment[uiTestsEnvironmentKey] == "1" else {
      return selectionKey
    }
    return "\(selectionKey).ui.\(ProcessInfo.processInfo.processIdentifier)"
  }

  static func hasStoredSelection() -> Bool {
    defaults.data(forKey: scopedSelectionKey) != nil
  }

  static func read() -> WorkspaceSelection? {
    guard
      let data = defaults.data(forKey: scopedSelectionKey),
      let storedSelection = try? JSONDecoder().decode(StoredWorkspaceSelection.self, from: data)
    else {
      return nil
    }
    return storedSelection.workspaceSelection
  }

  static func write(_ selection: WorkspaceSelection) {
    guard
      let data = try? JSONEncoder().encode(StoredWorkspaceSelection(workspaceSelection: selection))
    else {
      return
    }
    defaults.set(data, forKey: scopedSelectionKey)
  }

  static func clear() {
    defaults.removeObject(forKey: scopedSelectionKey)
  }
}

private struct StoredWorkspaceSelection: Codable {
  enum Kind: String, Codable {
    case create
    case decisions
    case decision
    case terminal
    case codex
    case agent
    case task
  }

  let kind: Kind
  let sessionID: String?
  let itemID: String?

  init(workspaceSelection: WorkspaceSelection) {
    switch workspaceSelection {
    case .create:
      kind = .create
      sessionID = nil
      itemID = nil
    case .decisions(let sessionID):
      kind = .decisions
      self.sessionID = sessionID
      itemID = nil
    case .decision(let sessionID, let decisionID):
      kind = .decision
      self.sessionID = sessionID
      itemID = decisionID
    case .terminal(let sessionID, let terminalID):
      kind = .terminal
      self.sessionID = sessionID
      itemID = terminalID
    case .codex(let sessionID, let runID):
      kind = .codex
      self.sessionID = sessionID
      itemID = runID
    case .agent(let sessionID, let agentID):
      kind = .agent
      self.sessionID = sessionID
      itemID = agentID
    case .task(let sessionID, let taskID):
      kind = .task
      self.sessionID = sessionID
      itemID = taskID
    }
  }

  var workspaceSelection: WorkspaceSelection? {
    let selection: WorkspaceSelection

    switch kind {
    case .create:
      selection = .create
    case .decisions:
      selection = .decisions(sessionID: sessionID)
    case .decision:
      guard let itemID else {
        return nil
      }
      selection = .decision(sessionID: sessionID, decisionID: itemID)
    case .terminal:
      guard let itemID else {
        return nil
      }
      selection = .terminal(sessionID: sessionID, terminalID: itemID)
    case .codex:
      guard let itemID else {
        return nil
      }
      selection = .codex(sessionID: sessionID, runID: itemID)
    case .agent:
      guard let itemID else {
        return nil
      }
      selection = .agent(sessionID: sessionID, agentID: itemID)
    case .task:
      guard let itemID else {
        return nil
      }
      selection = .task(sessionID: sessionID, taskID: itemID)
    }

    return selection
  }
}
