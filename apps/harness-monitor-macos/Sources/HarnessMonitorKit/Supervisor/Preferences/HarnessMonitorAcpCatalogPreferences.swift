import Foundation

public enum HarnessMonitorAcpCatalogPreferences {
  public static let appStorageKey = "harness.feature.acp"
  public static let environmentKey = "HARNESS_FEATURE_ACP"
  public static let defaultEnabled = false

  public static func storedValue(userDefaults: UserDefaults = .standard) -> Bool {
    guard let stored = userDefaults.object(forKey: appStorageKey) as? Bool else {
      return defaultEnabled
    }
    return stored
  }

  public static func environmentValue(
    from environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool? {
    parseBoolean(environment[environmentKey])
  }

  public static func effectiveValue(
    userDefaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    if let value = environmentValue(from: environment) {
      return value
    }
    return storedValue(userDefaults: userDefaults)
  }

  private static func parseBoolean(_ rawValue: String?) -> Bool? {
    guard let rawValue else {
      return nil
    }
    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on":
      return true
    case "0", "false", "no", "off":
      return false
    default:
      return nil
    }
  }
}
