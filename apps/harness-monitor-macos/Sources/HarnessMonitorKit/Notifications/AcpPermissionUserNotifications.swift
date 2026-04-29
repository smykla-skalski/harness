import Foundation

public struct AcpPermissionAttentionEvent: Equatable, Sendable, Identifiable {
  public let batchID: String
  public let decisionID: String
  public let agentID: String
  public let agentName: String
  public let requestCount: Int
  public let createdAt: String

  public init(
    batchID: String,
    decisionID: String,
    agentID: String,
    agentName: String,
    requestCount: Int,
    createdAt: String
  ) {
    self.batchID = batchID
    self.decisionID = decisionID
    self.agentID = agentID
    self.agentName = agentName
    self.requestCount = requestCount
    self.createdAt = createdAt
  }

  public var id: String { batchID }

  public var toastMessage: String {
    "Permission requested by \(agentName). Decisions window."
  }

  public var notificationBody: String {
    "Permission requested by \(agentName). Open the Decisions window."
  }

  public var notificationSubtitle: String {
    "Agent permission required"
  }
}

public enum AcpPermissionNotificationAuthorizationStatus: String, Equatable, Sendable {
  case unknown
  case notDetermined = "not-determined"
  case denied
  case provisional
  case authorized

  public var allowsUserNotificationDelivery: Bool {
    switch self {
    case .provisional, .authorized:
      true
    case .unknown, .notDetermined, .denied:
      false
    }
  }

  public var showsSystemSettingsLink: Bool {
    self == .denied
  }

  public var displayTitle: String {
    switch self {
    case .unknown:
      "Unknown"
    case .notDetermined:
      "Not requested"
    case .denied:
      "Denied"
    case .provisional:
      "Provisional"
    case .authorized:
      "Enabled"
    }
  }

  public var detailText: String {
    switch self {
    case .unknown:
      "Harness Monitor has not refreshed Notification Center status yet."
    case .notDetermined:
      "Notification Center delivery is available once system permission is granted."
    case .denied:
      "Notification Center delivery is disabled. Dock, badge, and Decisions routes stay available."
    case .provisional:
      "Notification Center delivery is available quietly until full alerts are granted."
    case .authorized:
      "Notification Center delivery is enabled for background ACP attention."
    }
  }
}

public enum AcpPermissionUserNotifications {
  public static let previewAuthorizationEnvironmentKey =
    "HARNESS_MONITOR_PREVIEW_NOTIFICATION_AUTHORIZATION"
  public static let systemSettingsURLString =
    "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

  public static var systemSettingsURL: URL? {
    URL(string: systemSettingsURLString)
  }

  public static func authorizationStatus(
    from snapshot: HarnessMonitorNotificationSettingsSnapshot
  ) -> AcpPermissionNotificationAuthorizationStatus {
    let normalized = normalize(snapshot.authorizationStatus)
    switch normalized {
    case "authorized", "granted", "enabled":
      return .authorized
    case "provisional":
      return .provisional
    case "denied":
      return .denied
    case "notdetermined":
      return .notDetermined
    default:
      return .unknown
    }
  }

  public static func previewSettingsSnapshot(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> HarnessMonitorNotificationSettingsSnapshot {
    snapshot(forPreviewAuthorization: environment[previewAuthorizationEnvironmentKey])
  }

  public static func snapshot(
    forPreviewAuthorization rawValue: String?
  ) -> HarnessMonitorNotificationSettingsSnapshot {
    switch normalize(rawValue ?? "") {
    case "authorized", "":
      .preview
    case "provisional":
      .init(
        authorizationStatus: "provisional",
        alertSetting: "disabled",
        soundSetting: "disabled",
        badgeSetting: "enabled",
        notificationCenterSetting: "enabled",
        lockScreenSetting: "disabled",
        alertStyle: "banner",
        showPreviews: "always",
        timeSensitiveSetting: "disabled",
        scheduledDeliverySetting: "not supported",
        directMessagesSetting: "not supported",
        providesAppNotificationSettings: true
      )
    case "notdetermined":
      .init(
        authorizationStatus: "not determined",
        alertSetting: "disabled",
        soundSetting: "disabled",
        badgeSetting: "disabled",
        notificationCenterSetting: "disabled",
        lockScreenSetting: "disabled",
        alertStyle: "none",
        showPreviews: "when unlocked",
        timeSensitiveSetting: "disabled",
        scheduledDeliverySetting: "not supported",
        directMessagesSetting: "not supported",
        providesAppNotificationSettings: true
      )
    case "denied":
      .init(
        authorizationStatus: "denied",
        alertSetting: "disabled",
        soundSetting: "disabled",
        badgeSetting: "disabled",
        notificationCenterSetting: "disabled",
        lockScreenSetting: "disabled",
        alertStyle: "none",
        showPreviews: "never",
        timeSensitiveSetting: "disabled",
        scheduledDeliverySetting: "not supported",
        directMessagesSetting: "not supported",
        providesAppNotificationSettings: true
      )
    default:
      .preview
    }
  }

  private static func normalize(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: "_", with: "")
  }
}
