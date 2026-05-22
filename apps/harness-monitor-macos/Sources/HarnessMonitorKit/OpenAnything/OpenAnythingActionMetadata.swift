extension OpenAnythingCorpusBuilder {
  static func actionTitle(_ action: OpenAnythingAction) -> String {
    actionTitles[action] ?? action.rawValue
  }

  static func actionSubtitle(_ action: OpenAnythingAction) -> String {
    switch action {
    case .newSession, .newTask, .attachExternalSession:
      "Create"
    case .openDashboard, .openTaskBoard, .openReviews, .openNotifications,
      .openPolicyCanvas, .openDiagnostics:
      "Navigate"
    case .refresh:
      "Reload Monitor data"
    case .refreshDiagnostics:
      "Reload daemon diagnostics"
    case .reconnectDaemon:
      "Restart the Monitor connection"
    case .copyDiagnostics:
      "Copy Monitor state"
    case .settings:
      "Open Settings"
    case .openMCPSettings:
      "Open Settings > MCP"
    case .openDatabaseSettings:
      "Open Settings > Database"
    case .policyCanvasLab:
      "Open experimental window"
    }
  }

  static func actionSystemImage(_ action: OpenAnythingAction) -> String {
    actionSystemImages[action] ?? OpenAnythingDomain.actions.systemImage
  }

  static let suggestedActions: Set<OpenAnythingAction> = [
    .newSession,
    .openTaskBoard,
    .openReviews,
    .openDiagnostics,
    .refresh,
  ]

  static func actionSearchAliases(_ action: OpenAnythingAction) -> String {
    switch action {
    case .openTaskBoard:
      "task board board operations dispatch"
    case .openReviews:
      "dependency pull requests prs renovate checks merge approvals"
    case .openDiagnostics, .refreshDiagnostics, .copyDiagnostics:
      "diagnostics health daemon cache provenance freshness mcp"
    case .reconnectDaemon:
      "reconnect daemon offline stale connection"
    case .openMCPSettings:
      "mcp accessibility registry host"
    case .openDatabaseSettings:
      "database cache sqlite persistence"
    case .openNotifications:
      "alerts notification history"
    case .openPolicyCanvas, .policyCanvasLab:
      "policy canvas graph"
    case .newSession, .newTask, .attachExternalSession, .openDashboard, .refresh, .settings:
      ""
    }
  }

  private static let actionTitles: [OpenAnythingAction: String] = [
    .newSession: "New Session",
    .newTask: "New Task",
    .attachExternalSession: "Attach External Session",
    .openDashboard: "Open Dashboard",
    .openTaskBoard: "Open Board",
    .openReviews: "Open Reviews",
    .openNotifications: "Open Notifications",
    .openPolicyCanvas: "Open Policy",
    .openDiagnostics: "Open Diagnostics",
    .refreshDiagnostics: "Refresh Diagnostics",
    .reconnectDaemon: "Reconnect Daemon",
    .copyDiagnostics: "Copy Diagnostics",
    .refresh: "Refresh",
    .settings: "Settings",
    .openMCPSettings: "Open MCP Settings",
    .openDatabaseSettings: "Open Database Settings",
    .policyCanvasLab: "Policy Canvas Lab",
  ]

  private static let actionSystemImages: [OpenAnythingAction: String] = [
    .newSession: "plus.rectangle.on.folder",
    .newTask: "checklist",
    .attachExternalSession: "link.badge.plus",
    .openDashboard: "square.grid.2x2",
    .openTaskBoard: "list.bullet.rectangle",
    .openReviews: "shippingbox.circle",
    .openNotifications: "bell.badge",
    .openPolicyCanvas: "point.3.connected.trianglepath.dotted",
    .openDiagnostics: "stethoscope",
    .refresh: "arrow.clockwise",
    .refreshDiagnostics: "stethoscope.circle",
    .reconnectDaemon: "arrow.triangle.2.circlepath",
    .copyDiagnostics: "doc.on.clipboard",
    .settings: "gearshape",
    .openMCPSettings: "point.3.connected.trianglepath.dotted",
    .openDatabaseSettings: "internaldrive",
    .policyCanvasLab: "point.3.connected.trianglepath.dotted",
  ]
}
