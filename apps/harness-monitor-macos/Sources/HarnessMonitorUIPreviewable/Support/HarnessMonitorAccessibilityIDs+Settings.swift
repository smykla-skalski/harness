extension HarnessMonitorAccessibility {
  public static func settingsSectionButton(_ key: String) -> String {
    "harness.settings.section.\(slug(key))"
  }

  public static func settingsActionButton(_ key: String) -> String {
    "harness.settings.action.\(slug(key))"
  }

  public static func settingsAcpPermissionLogRevealButton(_ runID: String) -> String {
    "harness.settings.diagnostics.acp-permission-log.reveal.\(slug(runID))"
  }

  public static func settingsAcpPermissionLogError(_ runID: String) -> String {
    "harness.settings.diagnostics.acp-permission-log.error.\(slug(runID))"
  }

  public static func settingsAcpPermissionLogRevealStatus(_ runID: String) -> String {
    "harness.settings.diagnostics.acp-permission-log.reveal-status.\(slug(runID))"
  }

  public static func settingsBackgroundTile(_ key: String) -> String {
    "harness.settings.background.\(slug(key))"
  }

  public static func segmentedOption(_ controlID: String, option: String) -> String {
    "\(controlID).option.\(slug(option))"
  }
}
