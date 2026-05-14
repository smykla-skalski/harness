import Foundation

public enum SessionWindowInitialRouteOverride {
  private static let environmentKey = "HARNESS_MONITOR_INITIAL_SESSION_ROUTE"
  private static let uiTestEnvironmentKey = "HARNESS_MONITOR_UI_TEST_SESSION_ROUTE"

  public static func route(
    values: [String: String],
    isUITesting: Bool
  ) -> SessionWindowRoute? {
    let rawValue = values[environmentKey] ?? (isUITesting ? values[uiTestEnvironmentKey] : nil)
    guard let rawValue else { return nil }
    let normalized = normalize(rawValue)
    guard !normalized.isEmpty else { return nil }

    return SessionWindowRoute.allCases.first { route in
      normalize(route.rawValue) == normalized || normalize(route.title) == normalized
    }
  }

  private static func normalize(_ value: String) -> String {
    String(
      value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .filter { character in
          character.isLetter || character.isNumber
        }
    )
      .lowercased()
  }
}
