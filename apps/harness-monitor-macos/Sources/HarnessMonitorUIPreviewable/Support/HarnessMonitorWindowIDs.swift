public enum HarnessMonitorWindowID {
  public static let main = "main"
  public static let settings = "settings"
  public static let workspace = "workspace"

  public static func sessionWindow(_ sessionID: String) -> String {
    "session-\(HarnessMonitorAccessibility.slug(sessionID))"
  }
}
