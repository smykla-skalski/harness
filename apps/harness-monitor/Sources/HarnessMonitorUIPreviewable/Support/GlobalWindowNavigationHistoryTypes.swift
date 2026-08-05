import HarnessMonitorKit
import SwiftUI

@MainActor
enum GlobalWindowNavigationEntry: Hashable {
  case dashboard(selection: DashboardWindowSelection)
  case session(sessionID: String, selection: SessionSelection)
}

enum DashboardWindowSelection: Hashable, Sendable {
  case route(DashboardWindowRoute)
  case agents(DashboardAgentNavigationTarget)
  case taskBoard(DashboardTaskBoardNavigationTarget)
  case audit(DashboardAuditNavigationTarget)
  case reviews(DashboardReviewsHistorySelection)

  var route: DashboardWindowRoute {
    switch self {
    case .route(let route):
      route
    case .agents:
      .agents
    case .taskBoard:
      .taskBoard
    case .audit:
      .audit
    case .reviews:
      .reviews
    }
  }

  var reviewsSelection: DashboardReviewsHistorySelection? {
    guard case .reviews(let selection) = self else {
      return nil
    }
    return selection
  }

  var agentIdentity: DashboardAgentIdentity? {
    guard case .agents(.identity(let identity)) = self else { return nil }
    return identity
  }

  var agentTarget: DashboardAgentNavigationTarget? {
    guard case .agents(let target) = self else { return nil }
    return target
  }
}

public enum DashboardAgentNavigationTarget: Hashable, Sendable {
  case identity(DashboardAgentIdentity)
  case session(sessionID: String)
  case sessionAgent(sessionID: String, agentID: String)
  case managedAgent(
    sessionID: String,
    runtimeKind: DashboardAgentRuntimeKind,
    managedAgentID: String
  )
  case decision(decisionID: String)
  case createTerminal(sessionID: String)
}

public enum DashboardTaskBoardNavigationTarget: Hashable, Sendable {
  case item(itemID: String)
  case sessionTask(sessionID: String, taskID: String)
  case loadedSessionTask(sessionID: String, taskID: String)
}

public enum DashboardAuditNavigationTarget: Hashable, Sendable {
  case auditEvent(eventID: String)
  case sessionTimeline(DashboardTimelineActivityTarget)
  case observerSummary(DashboardObserverActivityTarget)

  public init(eventID: String) {
    self = .auditEvent(eventID: eventID)
  }

  public var eventID: String {
    switch self {
    case .auditEvent(let eventID): eventID
    case .sessionTimeline(let activity): activity.auditEventID
    case .observerSummary(let activity): activity.auditEventID
    }
  }

  var routedEvent: HarnessMonitorAuditEvent? {
    switch self {
    case .auditEvent:
      nil
    case .sessionTimeline(let activity):
      activity.auditEvent
    case .observerSummary(let activity):
      activity.auditEvent
    }
  }
}

public struct DashboardObserverActivityTarget: Hashable, Sendable {
  public let sessionID: String
  public let observeID: String
  public let recordedAt: String
  public let openIssueCount: Int
  public let activeWorkerCount: Int
  public let payloadJSON: String?

  public init(sessionID: String, observer: ObserverSummary) {
    self.sessionID = sessionID
    observeID = observer.observeId
    recordedAt = observer.lastScanTime
    openIssueCount = observer.openIssueCount
    activeWorkerCount = observer.activeWorkerCount
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    payloadJSON = (try? encoder.encode(observer)).flatMap {
      String(bytes: $0, encoding: .utf8)
    }
  }

  var auditEventID: String {
    "observer:\(sessionID):\(observeID):\(recordedAt)"
  }

  var auditEvent: HarnessMonitorAuditEvent {
    HarnessMonitorAuditEvent(
      id: auditEventID,
      recordedAt: HarnessMonitorAuditEvent.parseDate(recordedAt) ?? .distantPast,
      source: "observer",
      category: "automation",
      kind: "observer.summary",
      severity: openIssueCount > 0 ? "warning" : "info",
      outcome: "recorded",
      title: "Observer summary",
      summary: "\(issueCountText), \(workerCountText)",
      subject: sessionID,
      correlationID: sessionID,
      actionKey: "observer.summary",
      payloadJSON: decodedPayload
    )
  }

  private var issueCountText: String {
    openIssueCount == 1 ? "1 open issue" : "\(openIssueCount) open issues"
  }

  private var workerCountText: String {
    activeWorkerCount == 1 ? "1 active worker" : "\(activeWorkerCount) active workers"
  }

  private var decodedPayload: JSONValue? {
    guard let payloadJSON, let data = payloadJSON.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
  }
}

public struct DashboardTimelineActivityTarget: Hashable, Sendable {
  public let sessionID: String
  public let entryID: String
  public let recordedAt: String
  public let kind: String
  public let agentID: String?
  public let taskID: String?
  public let summary: String
  public let payloadJSON: String?

  public init(_ target: OpenAnythingLoadedSessionTimelineTarget) {
    sessionID = target.sessionID
    entryID = target.entryID
    recordedAt = target.recordedAt
    kind = target.kind
    agentID = target.agentID
    taskID = target.taskID
    summary = target.summary
    payloadJSON = target.payloadJSON
  }

  var auditEventID: String {
    "timeline:\(sessionID):\(entryID)"
  }

  var auditEvent: HarnessMonitorAuditEvent {
    HarnessMonitorAuditEvent(
      id: auditEventID,
      recordedAt: HarnessMonitorAuditEvent.parseDate(recordedAt) ?? .distantPast,
      source: "sessionTimeline",
      category: "activity",
      kind: kind,
      severity: "info",
      outcome: "recorded",
      title: summary.isEmpty ? kind.replacingOccurrences(of: "_", with: " ").capitalized : summary,
      summary: summary.isEmpty ? kind : summary,
      subject: taskID ?? sessionID,
      actor: agentID,
      correlationID: sessionID,
      actionKey: kind,
      payloadJSON: decodedPayload
    )
  }

  private var decodedPayload: JSONValue? {
    guard let payloadJSON, let data = payloadJSON.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
  }
}

struct DashboardWindowNavigationRestoreRequest: Equatable, Sendable {
  let requestID: Int
  let selection: DashboardWindowSelection

  var route: DashboardWindowRoute { selection.route }
}

struct DashboardReviewsNavigationRestoreRequest: Equatable, Sendable {
  let requestID: Int
  let selection: DashboardReviewsHistorySelection
}

struct DashboardAgentsNavigationRestoreRequest: Equatable, Sendable {
  let requestID: Int
  let target: DashboardAgentNavigationTarget
}

struct DashboardTaskBoardNavigationRestoreRequest: Equatable, Sendable {
  let requestID: Int
  let target: DashboardTaskBoardNavigationTarget
}

struct DashboardAuditNavigationRestoreRequest: Equatable, Sendable {
  let requestID: Int
  let target: DashboardAuditNavigationTarget?
}

struct SessionWindowNavigationRestoreRequest: Equatable, Sendable {
  let requestID: Int
  let sessionID: String
  let selection: SessionSelection
}

@MainActor
public enum GlobalWindowNavigationHistoryRegistry {
  public static var current: GlobalWindowNavigationHistory?
}

private struct GlobalWindowNavigationHistoryKey: @preconcurrency EnvironmentKey {
  @MainActor static let defaultValue: GlobalWindowNavigationHistory? = nil
}

extension EnvironmentValues {
  public var globalWindowNavigationHistory: GlobalWindowNavigationHistory? {
    get { self[GlobalWindowNavigationHistoryKey.self] }
    set { self[GlobalWindowNavigationHistoryKey.self] = newValue }
  }
}
