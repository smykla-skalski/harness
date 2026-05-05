import Foundation
import HarnessMonitorKit

enum WorkspaceSelectionDefaults {
  static let selectionKey = "HarnessMonitor.Workspace.selection"

  private static let uiTestsEnvironmentKey = "HARNESS_MONITOR_UI_TESTS"
  private enum StorageScope {
    case live
    case processScoped(String)

    func selectionKey(baseKey: String, processID: Int32) -> String {
      switch self {
      case .live:
        baseKey
      case .processScoped(let label):
        "\(baseKey).\(label).\(processID)"
      }
    }
  }

  private static func scopedSelectionKey(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    processID: Int32 = ProcessInfo.processInfo.processIdentifier
  ) -> String {
    storageScope(environment: environment).selectionKey(baseKey: selectionKey, processID: processID)
  }

  private static func storageScope(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> StorageScope {
    if environment[uiTestsEnvironmentKey] == "1" {
      return .processScoped("ui")
    }
    if HarnessMonitorLaunchMode(environment: environment) != .live {
      return .processScoped("preview")
    }
    return .live
  }

  static func hasStoredSelection(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard
  ) -> Bool {
    defaults.data(forKey: scopedSelectionKey(environment: environment)) != nil
  }

  static func read(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard
  ) -> WorkspaceSelection? {
    guard
      let data = defaults.data(forKey: scopedSelectionKey(environment: environment)),
      let storedSelection = try? JSONDecoder().decode(StoredWorkspaceSelection.self, from: data)
    else {
      return nil
    }
    return storedSelection.workspaceSelection
  }

  static func write(
    _ selection: WorkspaceSelection,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard
  ) {
    guard
      let data = try? JSONEncoder().encode(StoredWorkspaceSelection(workspaceSelection: selection))
    else {
      return
    }
    defaults.set(data, forKey: scopedSelectionKey(environment: environment))
  }

  static func clear(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    defaults: UserDefaults = .standard
  ) {
    defaults.removeObject(forKey: scopedSelectionKey(environment: environment))
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
