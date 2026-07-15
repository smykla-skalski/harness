import Foundation

/// Persisted UI preference for the board-level Evaluate control. Defaults to
/// live so the primary action stays a real evaluation; operators opt into a
/// dry-run preview. Stored alongside the other task-board card/UI prefs.
enum TaskBoardEvaluatePreferences {
  static let dryRunStorageKey = "harness.task-board.evaluate.dry-run.v1"
  static let defaultDryRun = false

  static func dryRun(from userDefaults: UserDefaults = .standard) -> Bool {
    guard userDefaults.object(forKey: dryRunStorageKey) != nil else {
      return defaultDryRun
    }
    return userDefaults.bool(forKey: dryRunStorageKey)
  }

  static func setDryRun(_ isOn: Bool, in userDefaults: UserDefaults = .standard) {
    userDefaults.set(isOn, forKey: dryRunStorageKey)
  }
}
