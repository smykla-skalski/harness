import Foundation
import HarnessMonitorKit

enum HarnessMonitorAgentLaunchDefaults {
  static let preferredSelectionKey = "harness.agent-launch.preferred-selection"
  static let preferredProviderKey = "harness.agent-launch.preferred-provider"
  static let legacyTerminalCopilotExplicitKey =
    "harness.agent-launch.legacy-terminal-copilot-explicit"
  static let startupFallbackSelection = AgentLaunchSelection.codex
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

  static func preferredProviderID(
    userDefaults: UserDefaults = .standard
  ) -> String? {
    if let storedProvider = userDefaults.string(forKey: preferredProviderKey),
      !storedProvider.isEmpty
    {
      return storedProvider
    }
    guard hasExplicitPreferredSelection(userDefaults: userDefaults) else {
      return nil
    }
    return providerID(for: preferredSelection(userDefaults: userDefaults))
  }

  static func hasExplicitPreferredProvider(
    userDefaults: UserDefaults = .standard
  ) -> Bool {
    preferredProviderID(userDefaults: userDefaults) != nil
  }

  static func providerID(for selection: AgentLaunchSelection) -> String {
    switch selection {
    case .codex:
      AgentTuiRuntime.codex.rawValue
    case .tui(let runtime):
      runtime.rawValue
    case .acp(let id):
      id
    }
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
    userDefaults.set(providerID(for: selection), forKey: preferredProviderKey)
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
