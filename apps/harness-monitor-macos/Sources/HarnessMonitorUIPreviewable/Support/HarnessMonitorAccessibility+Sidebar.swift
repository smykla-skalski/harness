extension HarnessMonitorAccessibility {
  public static func autoSpawnedBadge(_ agentID: String) -> String {
    "harness.sidebar.agent.\(slug(agentID)).auto-spawned"
  }
}
