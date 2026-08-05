import Foundation

public struct HarnessMonitorMenuBarSnapshot: Equatable {
  public static let statusItemTitle = "Harness Monitor"
  public static let statusItemImageName = "HarnessMonitorMenuBarLighthouse"
  public static let statusItemInfoImageName = "HarnessMonitorMenuBarLighthouseInfo"
  public static let statusItemIdleImageName = statusItemInfoImageName
  public static let statusItemWarningImageName = "HarnessMonitorMenuBarLighthouseWarning"
  public static let statusItemCriticalImageName = "HarnessMonitorMenuBarLighthouseCritical"
  public static let openWorkspaceLabel = "Open Dashboard"
  public static let openSettingsLabel = "Settings"
  public static let refreshLabel = "Refresh"
  public static let checkSupervisorLabel = "Check Supervisor Now"
  public static let runWhenClosedLabel = "Run When Closed"
  public static let quitLabel = "Quit Harness Monitor"
  public static let activeMonitoringLabel = "Monitoring: Active work"
  public static let idleMonitoringLabel = "Monitoring: No active work"
  public static let activeStatusItemHelp = "Monitoring active work"
  public static let idleStatusItemHelp = "No active work"

  public let pendingDecisionCount: Int
  public let pendingDecisionSeverity: DecisionSeverity?
  public let isMonitoringIdle: Bool
  public let connectionLabel: String
  public let monitoringLabel: String
  public let activeWorkCountLabel: String
  public let pendingDecisionLabel: String
  public let supervisorLabel: String
  public let supervisorToggleLabel: String
  public let supervisorToggleDisabled: Bool

  public init(
    connectionState: HarnessMonitorStore.ConnectionState,
    pendingDecisionCount: Int,
    pendingDecisionSeverity: DecisionSeverity?,
    supervisorRuntimeState: HarnessMonitorStore.SupervisorRuntimeState,
    activeWorkCount: Int,
    runsWhenClosed: Bool
  ) {
    self.pendingDecisionCount = pendingDecisionCount
    self.pendingDecisionSeverity = pendingDecisionSeverity
    isMonitoringIdle = activeWorkCount <= 0
    connectionLabel = "Connection: \(Self.connectionTitle(connectionState))"
    monitoringLabel =
      isMonitoringIdle
      ? Self.idleMonitoringLabel
      : Self.activeMonitoringLabel
    activeWorkCountLabel = "Active work: \(Self.countTitle(activeWorkCount))"
    pendingDecisionLabel = "Decisions: \(Self.countTitle(pendingDecisionCount))"
    supervisorLabel = Self.supervisorLabel(
      supervisorRuntimeState,
      hasActiveWork: !isMonitoringIdle,
      runsWhenClosed: runsWhenClosed
    )
    supervisorToggleLabel = Self.supervisorToggleTitle(supervisorRuntimeState)
    supervisorToggleDisabled =
      supervisorRuntimeState == .starting
      || supervisorRuntimeState == .stopping
  }

  public var showsAttentionBadge: Bool {
    pendingDecisionCount > .zero
  }

  public var attentionBadgeTintLabel: String {
    Self.attentionTintLabel(for: pendingDecisionSeverity)
  }

  public var attentionBadgeAccessibilityLabel: String {
    guard showsAttentionBadge else {
      return "Attention badge: hidden"
    }
    return "Attention badge: \(attentionBadgeTintLabel)"
  }

  public var statusItemAccessibilitySummary: String {
    (Array(visibleMenuLabels.prefix(4)) + [attentionBadgeAccessibilityLabel])
      .joined(separator: ", ")
  }

  public var statusItemHelpText: String {
    isMonitoringIdle ? Self.idleStatusItemHelp : Self.activeStatusItemHelp
  }

  public var statusItemDisplayTitle: String {
    guard showsAttentionBadge else {
      return Self.statusItemTitle
    }
    let decisionNoun = pendingDecisionCount == 1 ? "decision" : "decisions"
    return "\(Self.statusItemTitle): \(Self.countTitle(pendingDecisionCount)) \(decisionNoun)"
  }

  public var statusItemAssetName: String {
    guard showsAttentionBadge else {
      return isMonitoringIdle ? Self.statusItemIdleImageName : Self.statusItemImageName
    }
    switch pendingDecisionSeverity {
    case .critical:
      return Self.statusItemCriticalImageName
    case .warn, .needsUser:
      return Self.statusItemWarningImageName
    case .none, .info:
      return Self.statusItemInfoImageName
    }
  }

  public var visibleMenuLabels: [String] {
    [
      connectionLabel,
      monitoringLabel,
      activeWorkCountLabel,
      pendingDecisionLabel,
      supervisorLabel,
      Self.openWorkspaceLabel,
      Self.openSettingsLabel,
      Self.refreshLabel,
      supervisorToggleLabel,
      Self.checkSupervisorLabel,
      Self.runWhenClosedLabel,
      Self.quitLabel,
    ]
  }

  private static func connectionTitle(
    _ state: HarnessMonitorStore.ConnectionState
  ) -> String {
    switch state {
    case .idle:
      "Idle"
    case .connecting:
      "Connecting"
    case .online:
      "Online"
    case .offline:
      "Offline"
    }
  }

  private static func supervisorTitle(
    _ state: HarnessMonitorStore.SupervisorRuntimeState
  ) -> String {
    switch state {
    case .stopped:
      "Stopped"
    case .starting:
      "Starting"
    case .running:
      "Running"
    case .stopping:
      "Stopping"
    }
  }

  private static func supervisorLabel(
    _ state: HarnessMonitorStore.SupervisorRuntimeState,
    hasActiveWork: Bool,
    runsWhenClosed: Bool
  ) -> String {
    if !hasActiveWork && state == .running && runsWhenClosed {
      return "Supervisor: Running in background"
    }
    return "Supervisor: \(supervisorTitle(state))"
  }

  private static func supervisorToggleTitle(
    _ state: HarnessMonitorStore.SupervisorRuntimeState
  ) -> String {
    switch state {
    case .stopped, .stopping:
      "Enable Supervisor"
    case .starting, .running:
      "Disable Supervisor"
    }
  }

  private static func countTitle(_ count: Int) -> String {
    switch count {
    case ..<0:
      "0"
    case 0...999:
      String(count)
    default:
      "999+"
    }
  }

  public static func statusItemHelpText(hasActiveWork: Bool) -> String {
    hasActiveWork ? activeStatusItemHelp : idleStatusItemHelp
  }

  public static func statusItemAccessibilityLabel(
    hasActiveWork: Bool,
    pendingDecisionCount: Int
  ) -> String {
    var components = [statusItemTitle]
    if !hasActiveWork {
      components.append(idleStatusItemHelp)
    }
    if pendingDecisionCount > 0 {
      let decisionNoun = pendingDecisionCount == 1 ? "decision" : "decisions"
      components.append("\(countTitle(pendingDecisionCount)) \(decisionNoun)")
    }
    return components.joined(separator: ": ")
  }

  private static func attentionTintLabel(for severity: DecisionSeverity?) -> String {
    switch severity {
    case .none, .info:
      "secondary"
    case .warn, .needsUser:
      "orange"
    case .critical:
      "red"
    }
  }
}
