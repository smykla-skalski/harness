import Foundation

enum HarnessMonitorAgentLaunchDefaults {
  static let preferredSelectionKey = "harness.agent-launch.preferred-selection"
  static let legacyTerminalCopilotExplicitKey =
    "harness.agent-launch.legacy-terminal-copilot-explicit"
  static let startupFallbackSelection = AgentLaunchSelection.tui(.codex)
  private static let legacyTerminalCopilotStorageKey =
    AgentLaunchSelection.tui(.copilot).storageKey

  static func preferredSelection(
    userDefaults: UserDefaults = .standard
  ) -> AgentLaunchSelection {
    guard
      let storedValue = userDefaults.string(forKey: preferredSelectionKey),
      let selection = AgentLaunchSelection(storageKey: storedValue)
    else {
      return startupFallbackSelection
    }
    if isImplicitLegacyTerminalCopilot(storedValue, userDefaults: userDefaults) {
      return startupFallbackSelection
    }
    return selection
  }

  static func hasExplicitPreferredSelection(
    userDefaults: UserDefaults = .standard
  ) -> Bool {
    guard let storedValue = userDefaults.string(forKey: preferredSelectionKey),
      AgentLaunchSelection(storageKey: storedValue) != nil
    else {
      return false
    }
    return !isImplicitLegacyTerminalCopilot(storedValue, userDefaults: userDefaults)
  }

  static func isImplicitLegacyTerminalCopilot(
    _ storageKey: String?,
    userDefaults: UserDefaults = .standard
  ) -> Bool {
    guard storageKey == legacyTerminalCopilotStorageKey else {
      return false
    }
    return !userDefaults.bool(forKey: legacyTerminalCopilotExplicitKey)
  }

  static func persist(
    _ selection: AgentLaunchSelection,
    userDefaults: UserDefaults = .standard
  ) {
    userDefaults.set(selection.storageKey, forKey: preferredSelectionKey)
    noteExplicitSelection(selection, userDefaults: userDefaults)
  }

  static func noteExplicitSelection(
    _ selection: AgentLaunchSelection,
    userDefaults: UserDefaults = .standard
  ) {
    guard selection.storageKey == legacyTerminalCopilotStorageKey else {
      return
    }
    userDefaults.set(true, forKey: legacyTerminalCopilotExplicitKey)
  }
}
