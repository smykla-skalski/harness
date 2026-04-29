import Foundation

enum HarnessMonitorAgentLaunchDefaults {
  static let preferredSelectionKey = "harness.agent-launch.preferred-selection"

  static func preferredSelection(
    userDefaults: UserDefaults = .standard
  ) -> AgentLaunchSelection {
    guard
      let storedValue = userDefaults.string(forKey: preferredSelectionKey),
      let selection = AgentLaunchSelection(storageKey: storedValue)
    else {
      return .tui(.copilot)
    }
    return selection
  }

  static func persist(
    _ selection: AgentLaunchSelection,
    userDefaults: UserDefaults = .standard
  ) {
    userDefaults.set(selection.storageKey, forKey: preferredSelectionKey)
  }
}
