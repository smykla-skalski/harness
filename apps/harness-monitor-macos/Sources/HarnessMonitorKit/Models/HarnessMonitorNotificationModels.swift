import Foundation
import UserNotifications

public enum HarnessMonitorNotificationAuthorizationProfile: String, CaseIterable, Identifiable,
  Sendable
{
  case standard
  case provisional

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .standard: "Alert, Sound, Badge"
    case .provisional: "Provisional"
    }
  }

  var options: UNAuthorizationOptions {
    switch self {
    case .standard:
      [.alert, .sound, .badge, .providesAppNotificationSettings]
    case .provisional:
      [.alert, .sound, .badge, .provisional, .providesAppNotificationSettings]
    }
  }
}

public enum HarnessMonitorNotificationCategoryKind: String, CaseIterable, Identifiable,
  Sendable
{
  case none
  case statusActions
  case textInput
  case fullControls

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .none: "No Actions"
    case .statusActions: "Status Actions"
    case .textInput: "Text Input"
    case .fullControls: "Full Controls"
    }
  }

  var categoryIdentifier: String {
    switch self {
    case .none: ""
    case .statusActions: HarnessMonitorNotificationCategoryID.statusActions
    case .textInput: HarnessMonitorNotificationCategoryID.textInput
    case .fullControls: HarnessMonitorNotificationCategoryID.fullControls
    }
  }
}

public enum HarnessMonitorNotificationSoundMode: String, CaseIterable, Identifiable, Sendable {
  case none
  case systemDefault

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .none: "None"
    case .systemDefault: "Default"
    }
  }
}

public enum HarnessMonitorNotificationAttachmentMode: String, CaseIterable, Identifiable,
  Sendable
{
  case none
  case sampleImage

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .none: "None"
    case .sampleImage: "Generated Image"
    }
  }
}

public enum HarnessMonitorNotificationThumbnailClipping: String, CaseIterable, Identifiable,
  Sendable
{
  case full
  case center
  case top

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .full: "Full"
    case .center: "Center"
    case .top: "Top"
    }
  }

  var rect: CGRect {
    switch self {
    case .full:
      CGRect(x: 0, y: 0, width: 1, height: 1)
    case .center:
      CGRect(x: 0.18, y: 0.16, width: 0.64, height: 0.68)
    case .top:
      CGRect(x: 0, y: 0, width: 1, height: 0.55)
    }
  }
}

public enum HarnessMonitorNotificationTriggerMode: String, CaseIterable, Identifiable, Sendable {
  case immediate
  case timeInterval
  case calendar

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .immediate: "Immediate"
    case .timeInterval: "Delay"
    case .calendar: "Calendar"
    }
  }
}

public enum HarnessMonitorNotificationInterruptionMode: String, CaseIterable, Identifiable,
  Sendable
{
  case passive
  case active
  case timeSensitive

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .passive: "Passive"
    case .active: "Active"
    case .timeSensitive: "Time Sensitive"
    }
  }

  var interruptionLevel: UNNotificationInterruptionLevel {
    switch self {
    case .passive: .passive
    case .active: .active
    case .timeSensitive: .timeSensitive
    }
  }
}

public struct HarnessMonitorNotificationDraft: Equatable, Sendable {
  public var title: String
  public var subtitle: String
  public var body: String
  public var threadIdentifier: String
  public var targetContentIdentifier: String
  public var filterCriteria: String
  public var summaryArgument: String
  public var summaryArgumentCount: Int
  public var includesBadge: Bool
  public var badgeNumber: Int
  public var includesUserInfo: Bool
  public var category: HarnessMonitorNotificationCategoryKind
  public var soundMode: HarnessMonitorNotificationSoundMode
  public var attachmentMode: HarnessMonitorNotificationAttachmentMode
  public var hidesAttachmentThumbnail: Bool
  public var thumbnailClipping: HarnessMonitorNotificationThumbnailClipping
  public var thumbnailTime: Double
  public var interruptionMode: HarnessMonitorNotificationInterruptionMode
  public var relevanceScore: Double
  public var triggerMode: HarnessMonitorNotificationTriggerMode
  public var delaySeconds: Double
  public var calendarDate: Date

  public init(
    title: String = "Harness Monitor",
    subtitle: String = "Manual notification test",
    body: String = "This notification was scheduled from Preferences.",
    threadIdentifier: String = "manual-tests",
    targetContentIdentifier: String = "preferences-notifications",
    filterCriteria: String = "manual",
    summaryArgument: String = "Harness Monitor",
    summaryArgumentCount: Int = 1,
    includesBadge: Bool = false,
    badgeNumber: Int = 1,
    includesUserInfo: Bool = true,
    category: HarnessMonitorNotificationCategoryKind = .fullControls,
    soundMode: HarnessMonitorNotificationSoundMode = .systemDefault,
    attachmentMode: HarnessMonitorNotificationAttachmentMode = .sampleImage,
    hidesAttachmentThumbnail: Bool = false,
    thumbnailClipping: HarnessMonitorNotificationThumbnailClipping = .full,
    thumbnailTime: Double = 0,
    interruptionMode: HarnessMonitorNotificationInterruptionMode = .active,
    relevanceScore: Double = 0.7,
    triggerMode: HarnessMonitorNotificationTriggerMode = .immediate,
    delaySeconds: Double = 5,
    calendarDate: Date = Date().addingTimeInterval(60)
  ) {
    self.title = title
    self.subtitle = subtitle
    self.body = body
    self.threadIdentifier = threadIdentifier
    self.targetContentIdentifier = targetContentIdentifier
    self.filterCriteria = filterCriteria
    self.summaryArgument = summaryArgument
    self.summaryArgumentCount = summaryArgumentCount
    self.includesBadge = includesBadge
    self.badgeNumber = badgeNumber
    self.includesUserInfo = includesUserInfo
    self.category = category
    self.soundMode = soundMode
    self.attachmentMode = attachmentMode
    self.hidesAttachmentThumbnail = hidesAttachmentThumbnail
    self.thumbnailClipping = thumbnailClipping
    self.thumbnailTime = thumbnailTime
    self.interruptionMode = interruptionMode
    self.relevanceScore = relevanceScore
    self.triggerMode = triggerMode
    self.delaySeconds = delaySeconds
    self.calendarDate = calendarDate
  }
}

public struct HarnessMonitorNotificationSettingsSnapshot: Equatable, Sendable {
  public var authorizationStatus: String
  public var alertSetting: String
  public var soundSetting: String
  public var badgeSetting: String
  public var notificationCenterSetting: String
  public var lockScreenSetting: String
  public var alertStyle: String
  public var showPreviews: String
  public var timeSensitiveSetting: String
  public var scheduledDeliverySetting: String
  public var directMessagesSetting: String
  public var providesAppNotificationSettings: Bool

  public static let unknown = Self(
    authorizationStatus: "unknown",
    alertSetting: "unknown",
    soundSetting: "unknown",
    badgeSetting: "unknown",
    notificationCenterSetting: "unknown",
    lockScreenSetting: "unknown",
    alertStyle: "unknown",
    showPreviews: "unknown",
    timeSensitiveSetting: "unknown",
    scheduledDeliverySetting: "unknown",
    directMessagesSetting: "unknown",
    providesAppNotificationSettings: false
  )

  public static let preview = Self(
    authorizationStatus: "authorized",
    alertSetting: "enabled",
    soundSetting: "enabled",
    badgeSetting: "enabled",
    notificationCenterSetting: "enabled",
    lockScreenSetting: "enabled",
    alertStyle: "banner",
    showPreviews: "always",
    timeSensitiveSetting: "enabled",
    scheduledDeliverySetting: "not supported",
    directMessagesSetting: "not supported",
    providesAppNotificationSettings: true
  )
}

public struct HarnessMonitorNotificationResponseSnapshot: Equatable, Sendable {
  public let actionIdentifier: String
  public let requestIdentifier: String
  public let categoryIdentifier: String
  public let textInput: String?
  public let receivedAt: Date

  init(response: UNNotificationResponse, receivedAt: Date = Date()) {
    self.actionIdentifier = response.actionIdentifier
    self.requestIdentifier = response.notification.request.identifier
    self.categoryIdentifier = response.notification.request.content.categoryIdentifier
    if let textInputResponse = response as? UNTextInputNotificationResponse {
      self.textInput = textInputResponse.userText
    } else {
      self.textInput = nil
    }
    self.receivedAt = receivedAt
  }
}

enum HarnessMonitorNotificationCategoryID {
  static let statusActions = "io.harnessmonitor.notifications.status-actions"
  static let textInput = "io.harnessmonitor.notifications.text-input"
  static let fullControls = "io.harnessmonitor.notifications.full-controls"
}

enum HarnessMonitorNotificationActionID {
  static let acknowledge = "io.harnessmonitor.notifications.action.acknowledge"
  static let open = "io.harnessmonitor.notifications.action.open"
  static let retry = "io.harnessmonitor.notifications.action.retry"
  static let delete = "io.harnessmonitor.notifications.action.delete"
  static let reply = "io.harnessmonitor.notifications.action.reply"
}
