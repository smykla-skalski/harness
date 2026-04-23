import CoreGraphics
import Foundation
import UserNotifications

public enum HarnessMonitorNotificationError: Error, LocalizedError, Equatable {
  case assetGenerationFailed(String)
  case invalidTrigger(String)

  public var errorDescription: String? {
    switch self {
    case .assetGenerationFailed(let asset):
      "Failed to generate notification asset: \(asset)"
    case .invalidTrigger(let reason):
      "Invalid notification trigger: \(reason)"
    }
  }
}

enum HarnessMonitorNotificationRequestFactory {
  static func makeRequest(
    from draft: HarnessMonitorNotificationDraft,
    assetWriter: HarnessMonitorNotificationAssetWriting,
    identifier: String = "harness-monitor-\(UUID().uuidString)"
  ) async throws -> UNNotificationRequest {
    let content = try await makeContent(from: draft, assetWriter: assetWriter)
    let trigger = try makeTrigger(from: draft)
    return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
  }

  static func makeContent(
    from draft: HarnessMonitorNotificationDraft,
    assetWriter: HarnessMonitorNotificationAssetWriting
  ) async throws -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    content.subtitle = draft.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    content.body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
    content.threadIdentifier = draft.threadIdentifier.trimmingCharacters(
      in: .whitespacesAndNewlines)
    content.targetContentIdentifier = optionalTrimmed(draft.targetContentIdentifier)
    content.filterCriteria = optionalTrimmed(draft.filterCriteria)
    content.summaryArgument = draft.summaryArgument.trimmingCharacters(in: .whitespacesAndNewlines)
    content.summaryArgumentCount = max(1, draft.summaryArgumentCount)
    content.categoryIdentifier = draft.category.categoryIdentifier
    content.interruptionLevel = draft.interruptionMode.interruptionLevel
    content.relevanceScore = min(1, max(0, draft.relevanceScore))
    content.sound = try await sound(from: draft, assetWriter: assetWriter)

    if draft.includesBadge {
      content.badge = NSNumber(value: max(0, draft.badgeNumber))
    }
    if draft.includesUserInfo {
      content.userInfo = [
        "source": "preferences",
        "thread": draft.threadIdentifier,
        "presetCategory": draft.category.rawValue,
      ]
    }
    content.attachments = try await attachments(from: draft, assetWriter: assetWriter)
    return content
  }

  static func makeTrigger(
    from draft: HarnessMonitorNotificationDraft
  ) throws -> UNNotificationTrigger? {
    switch draft.triggerMode {
    case .immediate:
      nil
    case .timeInterval:
      UNTimeIntervalNotificationTrigger(
        timeInterval: max(1, draft.delaySeconds),
        repeats: false
      )
    case .calendar:
      try calendarTrigger(for: draft.calendarDate)
    }
  }

  /// Builds a `UNNotificationRequest` for a supervisor `Decision` notification. The request
  /// carries the decision id inside `userInfo` so the tap handler can route back into the
  /// Decisions window via `HarnessMonitorUserNotificationController.decisionRequestedID`.
  ///
  /// Severity → interruption-level mapping:
  /// - `.info` -> `.passive`
  /// - `.warn` -> `.active`
  /// - `.needsUser` / `.critical` -> `.timeSensitive`
  ///
  /// Each severity maps to a unique category identifier so Notification Center can attach
  /// per-severity actions (`Open` + `Acknowledge`).
  static func makeSupervisorRequest(
    severity: DecisionSeverity,
    summary: String,
    decisionID: String
  ) async throws -> UNNotificationRequest {
    let preferences = SupervisorNotificationPreferences.load()
    let content = UNMutableNotificationContent()
    content.title = "Harness Monitor"
    content.subtitle = severity.supervisorNotificationSubtitle
    content.body = summary
    content.threadIdentifier = HarnessMonitorSupervisorNotificationID.threadIdentifier
    content.categoryIdentifier = HarnessMonitorSupervisorNotificationID.category(for: severity)
    content.interruptionLevel = severity.supervisorInterruptionLevel
    content.relevanceScore = severity.supervisorRelevanceScore
    content.sound = preferences.requestSound(for: severity)
    content.userInfo = [
      HarnessMonitorSupervisorNotificationID.decisionIDKey: decisionID,
      HarnessMonitorSupervisorNotificationID.severityKey: severity.rawValue,
    ]
    let identifier = "\(HarnessMonitorSupervisorNotificationID.requestPrefix)\(decisionID)"
    return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
  }

  /// Convenience helper mirroring `makeSupervisorRequest` that produces a
  /// `HarnessMonitorNotificationDraft` for surfaces that still use the Preferences draft flow
  /// (for example, the debug "Send test supervisor notification" affordance).
  static func supervisorDecision(
    severity: DecisionSeverity,
    summary: String,
    decisionID: String
  ) -> HarnessMonitorNotificationDraft {
    HarnessMonitorNotificationDraft(
      title: "Harness Monitor",
      subtitle: severity.supervisorNotificationSubtitle,
      body: summary,
      threadIdentifier: HarnessMonitorSupervisorNotificationID.threadIdentifier,
      targetContentIdentifier: decisionID,
      filterCriteria: severity.rawValue,
      summaryArgument: "Harness Monitor",
      summaryArgumentCount: 1,
      includesBadge: false,
      badgeNumber: 0,
      includesUserInfo: true,
      category: .fullControls,
      soundMode: severity == .info ? .none : .systemDefault,
      attachmentMode: .none,
      hidesAttachmentThumbnail: true,
      thumbnailClipping: .full,
      thumbnailTime: 0,
      interruptionMode: severity.supervisorDraftInterruptionMode,
      relevanceScore: severity.supervisorRelevanceScore,
      triggerMode: .immediate,
      delaySeconds: 0,
      calendarDate: Date().addingTimeInterval(60)
    )
  }

  static func categories() -> Set<UNNotificationCategory> {
    let acknowledge = UNNotificationAction(
      identifier: HarnessMonitorNotificationActionID.acknowledge,
      title: "Acknowledge",
      options: [],
      icon: UNNotificationActionIcon(systemImageName: "checkmark.circle")
    )
    let open = UNNotificationAction(
      identifier: HarnessMonitorNotificationActionID.open,
      title: "Open",
      options: [.foreground],
      icon: UNNotificationActionIcon(systemImageName: "arrow.up.forward.app")
    )
    let retry = UNNotificationAction(
      identifier: HarnessMonitorNotificationActionID.retry,
      title: "Retry",
      options: [.authenticationRequired],
      icon: UNNotificationActionIcon(systemImageName: "arrow.clockwise")
    )
    let delete = UNNotificationAction(
      identifier: HarnessMonitorNotificationActionID.delete,
      title: "Delete",
      options: [.destructive],
      icon: UNNotificationActionIcon(systemImageName: "trash")
    )
    let reply = UNTextInputNotificationAction(
      identifier: HarnessMonitorNotificationActionID.reply,
      title: "Reply",
      options: [.foreground],
      icon: UNNotificationActionIcon(systemImageName: "text.bubble"),
      textInputButtonTitle: "Send",
      textInputPlaceholder: "Reply with updated run context"
    )

    var categories: Set<UNNotificationCategory> = [
      UNNotificationCategory(
        identifier: HarnessMonitorNotificationCategoryID.statusActions,
        actions: [acknowledge, open],
        intentIdentifiers: [],
        hiddenPreviewsBodyPlaceholder: "Harness Monitor status",
        categorySummaryFormat: "%u Harness Monitor updates",
        options: [.hiddenPreviewsShowTitle, .customDismissAction]
      ),
      UNNotificationCategory(
        identifier: HarnessMonitorNotificationCategoryID.textInput,
        actions: [reply, open],
        intentIdentifiers: [],
        hiddenPreviewsBodyPlaceholder: "Harness Monitor request",
        categorySummaryFormat: "%u Harness Monitor requests",
        options: [.hiddenPreviewsShowTitle, .hiddenPreviewsShowSubtitle, .customDismissAction]
      ),
      UNNotificationCategory(
        identifier: HarnessMonitorNotificationCategoryID.fullControls,
        actions: [acknowledge, open, retry, delete, reply],
        intentIdentifiers: [],
        hiddenPreviewsBodyPlaceholder: "Harness Monitor notification",
        categorySummaryFormat: "%u Harness Monitor notifications",
        options: [.hiddenPreviewsShowTitle, .hiddenPreviewsShowSubtitle, .customDismissAction]
      ),
    ]
    for severity in DecisionSeverity.allCases {
      categories.insert(
        UNNotificationCategory(
          identifier: HarnessMonitorSupervisorNotificationID.category(for: severity),
          actions: [open, acknowledge],
          intentIdentifiers: [],
          hiddenPreviewsBodyPlaceholder: "Harness Monitor supervisor decision",
          categorySummaryFormat: "%u Harness Monitor supervisor decisions",
          options: [.hiddenPreviewsShowTitle, .hiddenPreviewsShowSubtitle, .customDismissAction]
        ))
    }
    return categories
  }

  private static func sound(
    from draft: HarnessMonitorNotificationDraft,
    assetWriter: HarnessMonitorNotificationAssetWriting
  ) async throws -> UNNotificationSound? {
    switch draft.soundMode {
    case .none:
      nil
    case .systemDefault:
      .default
    }
  }

  private static func attachments(
    from draft: HarnessMonitorNotificationDraft,
    assetWriter: HarnessMonitorNotificationAssetWriting
  ) async throws -> [UNNotificationAttachment] {
    switch draft.attachmentMode {
    case .none:
      []
    case .sampleImage:
      [
        try UNNotificationAttachment(
          identifier: "harness-monitor-sample-image",
          url: try await assetWriter.sampleImageURL(),
          options: attachmentOptions(from: draft)
        )
      ]
    }
  }

  private static func attachmentOptions(
    from draft: HarnessMonitorNotificationDraft
  ) -> [String: Any] {
    [
      UNNotificationAttachmentOptionsTypeHintKey: "public.png",
      UNNotificationAttachmentOptionsThumbnailHiddenKey: draft.hidesAttachmentThumbnail,
      UNNotificationAttachmentOptionsThumbnailClippingRectKey:
        draft.thumbnailClipping.rect.dictionaryRepresentation,
      UNNotificationAttachmentOptionsThumbnailTimeKey: draft.thumbnailTime,
    ]
  }

  private static func calendarTrigger(for date: Date) throws -> UNCalendarNotificationTrigger {
    let scheduledDate = max(date, Date().addingTimeInterval(1))
    let calendar = Calendar.current
    var components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: scheduledDate
    )
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    guard components.date != nil else {
      throw HarnessMonitorNotificationError.invalidTrigger("calendar date could not be encoded")
    }
    return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
  }

  private static func optionalTrimmed(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// Constants used by supervisor notifications. Category identifiers, the shared thread, and
/// `userInfo` keys all live together so the controller tap handler and the factory stay in sync.
public enum HarnessMonitorSupervisorNotificationID {
  public static let threadIdentifier = "io.harnessmonitor.supervisor"
  public static let requestPrefix = "io.harnessmonitor.supervisor.decision."
  public static let decisionIDKey = "io.harnessmonitor.supervisor.decisionID"
  public static let severityKey = "io.harnessmonitor.supervisor.severity"

  public static func category(for severity: DecisionSeverity) -> String {
    switch severity {
    case .info: "io.harnessmonitor.supervisor.category.info"
    case .warn: "io.harnessmonitor.supervisor.category.warn"
    case .needsUser: "io.harnessmonitor.supervisor.category.needsUser"
    case .critical: "io.harnessmonitor.supervisor.category.critical"
    }
  }
}

extension DecisionSeverity {
  fileprivate var supervisorInterruptionLevel: UNNotificationInterruptionLevel {
    switch self {
    case .info: .passive
    case .warn: .active
    case .needsUser, .critical: .timeSensitive
    }
  }

  fileprivate var supervisorDraftInterruptionMode: HarnessMonitorNotificationInterruptionMode {
    switch self {
    case .info: .passive
    case .warn: .active
    case .needsUser, .critical: .timeSensitive
    }
  }

  fileprivate var supervisorRelevanceScore: Double {
    switch self {
    case .info: 0.25
    case .warn: 0.55
    case .needsUser: 0.8
    case .critical: 1
    }
  }

  fileprivate var supervisorSound: UNNotificationSound? {
    switch self {
    case .info: nil
    case .warn, .needsUser: .default
    case .critical: .defaultCritical
    }
  }

  fileprivate var supervisorNotificationSubtitle: String {
    switch self {
    case .info: "Update"
    case .warn: "Heads up"
    case .needsUser: "Needs your decision"
    case .critical: "Critical"
    }
  }
}
