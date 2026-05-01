extension HarnessMonitorAccessibility {
  public static func preferencesSectionButton(_ key: String) -> String {
    "harness.preferences.section.\(slug(key))"
  }

  public static func preferencesActionButton(_ key: String) -> String {
    "harness.preferences.action.\(slug(key))"
  }

  public static func preferencesAcpPermissionLogRevealButton(_ runID: String) -> String {
    "harness.preferences.diagnostics.acp-permission-log.reveal.\(slug(runID))"
  }

  public static func preferencesAcpPermissionLogError(_ runID: String) -> String {
    "harness.preferences.diagnostics.acp-permission-log.error.\(slug(runID))"
  }

  public static func preferencesAcpPermissionLogRevealStatus(_ runID: String) -> String {
    "harness.preferences.diagnostics.acp-permission-log.reveal-status.\(slug(runID))"
  }

  public static func preferencesBackgroundTile(_ key: String) -> String {
    "harness.preferences.background.\(slug(key))"
  }

  public static func segmentedOption(_ controlID: String, option: String) -> String {
    "\(controlID).option.\(slug(option))"
  }
}
