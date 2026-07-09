import Foundation
import UserNotifications

public struct NotificationHistoryDetailRow: Codable, Equatable, Hashable, Sendable {
  public let label: String
  public let value: String

  public init(label: String, value: String) {
    self.label = label
    self.value = value
  }

  init(_ row: ActionFeedbackDetailRow) {
    self.init(label: row.label, value: row.value)
  }
}

public struct NotificationHistoryDetails: Codable, Equatable, Hashable, Sendable {
  public let disclosureLabel: String
  public let summary: String?
  public let rows: [NotificationHistoryDetailRow]
  public let command: String?

  public init(
    disclosureLabel: String = "details",
    summary: String? = nil,
    rows: [NotificationHistoryDetailRow] = [],
    command: String? = nil
  ) {
    self.disclosureLabel = disclosureLabel
    self.summary = summary
    self.rows = rows
    self.command = command
  }

  init(_ details: ActionFeedbackDetails) {
    self.init(
      disclosureLabel: details.disclosureLabel,
      summary: details.summary,
      rows: details.rows.map(NotificationHistoryDetailRow.init),
      command: details.command
    )
  }
}

public struct NotificationHistoryAction: Identifiable, Codable, Equatable, Hashable, Sendable {
  public enum Kind: Codable, Equatable, Hashable, Sendable {
    case copy(text: String)
    case openDecision(decisionID: String)
    case acknowledgeDecision(decisionID: String)
    case runtimeUndo(token: String)
  }

  public let id: String
  public let title: String
  public let systemImage: String
  public let kind: Kind
  public let successAnnouncement: String?

  public init(
    id: String,
    title: String,
    systemImage: String,
    kind: Kind,
    successAnnouncement: String? = nil
  ) {
    self.id = id
    self.title = title
    self.systemImage = systemImage
    self.kind = kind
    self.successAnnouncement = successAnnouncement
  }

  init(id: String, action: ActionFeedbackAction) {
    let kind: Kind
    switch action.kind {
    case .copy(let text):
      kind = .copy(text: text)
    }

    self.init(
      id: id,
      title: action.title,
      systemImage: action.systemImage,
      kind: kind,
      successAnnouncement: action.successAnnouncement
    )
  }

  public var isRuntimeOnly: Bool {
    if case .runtimeUndo = kind {
      return true
    }
    return false
  }
}

public struct NotificationHistoryEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
  public enum Source: String, Codable, CaseIterable, Sendable {
    case toast
    case supervisorDecision
    case supervisorNotice
    case acpPermission
    case settingsDraft

    public var label: String {
      switch self {
      case .toast:
        return "Toast"
      case .supervisorDecision:
        return "Supervisor"
      case .supervisorNotice:
        return "Supervisor Notice"
      case .acpPermission:
        return "ACP Permission"
      case .settingsDraft:
        return "Notification Center"
      }
    }
  }

  public enum Severity: String, Codable, CaseIterable, Sendable {
    case info
    case success
    case warning
    case failure
    case attention
  }

  public enum Status: String, Codable, CaseIterable, Sendable {
    case active
    case delivered
    case dismissed
    case evicted
    case opened
    case acknowledged
    case acted
    case undone
  }

  public let id: String
  public var recordedAt: Date
  public var updatedAt: Date
  public var source: Source
  public var severity: Severity
  public var status: Status
  public var statusText: String
  public var title: String?
  public var subtitle: String?
  public var message: String
  public var details: NotificationHistoryDetails?
  public var actions: [NotificationHistoryAction]
  public var repeatCount: Int
  public var accessibilityIdentifier: String?
  public var categoryIdentifier: String?
  public var requestIdentifier: String?
  public var decisionID: String?
  public var responseActionIdentifier: String?
  public var responseText: String?
  public var dropsOnRelaunch: Bool

  public init(
    id: String,
    recordedAt: Date,
    updatedAt: Date,
    source: Source,
    severity: Severity,
    status: Status,
    statusText: String,
    title: String? = nil,
    subtitle: String? = nil,
    message: String,
    details: NotificationHistoryDetails? = nil,
    actions: [NotificationHistoryAction] = [],
    repeatCount: Int = 1,
    accessibilityIdentifier: String? = nil,
    categoryIdentifier: String? = nil,
    requestIdentifier: String? = nil,
    decisionID: String? = nil,
    responseActionIdentifier: String? = nil,
    responseText: String? = nil,
    dropsOnRelaunch: Bool = false
  ) {
    self.id = id
    self.recordedAt = recordedAt
    self.updatedAt = updatedAt
    self.source = source
    self.severity = severity
    self.status = status
    self.statusText = statusText
    self.title = title
    self.subtitle = subtitle
    self.message = message
    self.details = details
    self.actions = actions
    self.repeatCount = repeatCount
    self.accessibilityIdentifier = accessibilityIdentifier
    self.categoryIdentifier = categoryIdentifier
    self.requestIdentifier = requestIdentifier
    self.decisionID = decisionID
    self.responseActionIdentifier = responseActionIdentifier
    self.responseText = responseText
    self.dropsOnRelaunch = dropsOnRelaunch
  }

  public var hasRuntimeOnlyAction: Bool {
    actions.contains(where: \.isRuntimeOnly)
  }
}

extension NotificationHistoryEntry.Severity {
  init(_ severity: ActionFeedback.Severity) {
    switch severity {
    case .activity:
      self = .info
    case .success:
      self = .success
    case .warning:
      self = .warning
    case .failure:
      self = .failure
    case .undoable:
      self = .attention
    }
  }

  init(_ severity: DecisionSeverity) {
    switch severity {
    case .info:
      self = .info
    case .warn:
      self = .warning
    case .needsUser:
      self = .attention
    case .critical:
      self = .failure
    }
  }
}

public struct ToastHistoryEvent: Equatable, Sendable {
  public enum DismissReason: String, Codable, Equatable, Sendable {
    case manual
    case timedOut
    case evicted
    case undoInvoked
  }

  public enum Kind: Equatable, Sendable {
    case presented
    case refreshed
    case dismissed(DismissReason)
  }

  public let feedback: ActionFeedback
  public let recordedAt: Date
  public let kind: Kind
  public let hasUndoAction: Bool

  public init(
    feedback: ActionFeedback,
    recordedAt: Date,
    kind: Kind,
    hasUndoAction: Bool
  ) {
    self.feedback = feedback
    self.recordedAt = recordedAt
    self.kind = kind
    self.hasUndoAction = hasUndoAction
  }
}

public struct NotificationHistoryRequestSnapshot: Equatable, Sendable {
  public let identifier: String
  public let title: String
  public let subtitle: String
  public let body: String
  public let threadIdentifier: String
  public let categoryIdentifier: String
  public let userInfo: [String: String]
  public let scheduledAt: Date

  init(request: UNNotificationRequest, scheduledAt: Date = .now) {
    self.identifier = request.identifier
    self.title = request.content.title
    self.subtitle = request.content.subtitle
    self.body = request.content.body
    self.threadIdentifier = request.content.threadIdentifier
    self.categoryIdentifier = request.content.categoryIdentifier
    self.userInfo = request.content.userInfo.reduce(into: [:]) { partialResult, pair in
      partialResult[String(describing: pair.key)] =
        pair.value as? String
        ?? String(describing: pair.value)
    }
    self.scheduledAt = scheduledAt
  }
}

public struct NotificationHistoryResponseUpdate: Equatable, Sendable {
  public let requestIdentifier: String
  public let actionIdentifier: String
  public let categoryIdentifier: String
  public let decisionID: String?
  public let textInput: String?
  public let receivedAt: Date

  init(snapshot: HarnessMonitorNotificationResponseSnapshot, decisionID: String?) {
    self.requestIdentifier = snapshot.requestIdentifier
    self.actionIdentifier = snapshot.actionIdentifier
    self.categoryIdentifier = snapshot.categoryIdentifier
    self.decisionID = decisionID
    self.textInput = snapshot.textInput
    self.receivedAt = snapshot.receivedAt
  }
}

public enum NotificationHistorySystemEvent: Equatable, Sendable {
  case scheduled(
    request: NotificationHistoryRequestSnapshot,
    source: NotificationHistoryEntry.Source,
    severity: NotificationHistoryEntry.Severity,
    actions: [NotificationHistoryAction]
  )
  case responded(NotificationHistoryResponseUpdate)
}
