public enum HarnessMonitorWindowID {
  public static let dashboard = "open-recent"
  public static let sessionScene = "session"
  public static let policyCanvasLab = "policy-canvas-lab"
  public static let settings = "settings"

  public static func sessionWindow(_ sessionID: String) -> String {
    "session-\(HarnessMonitorAccessibility.slug(sessionID))"
  }
}
