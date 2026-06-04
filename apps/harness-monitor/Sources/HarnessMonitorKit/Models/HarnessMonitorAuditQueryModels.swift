import Foundation

public struct HarnessMonitorAuditDateRange: Codable, Equatable, Sendable {
  public var start: String?
  public var end: String?

  public init(start: String? = nil, end: String? = nil) {
    self.start = start
    self.end = end
  }
}

struct DashboardReviewActionAuditBackfillEntry: Codable, Equatable, Sendable {
  enum Outcome: String, Codable, Equatable, Sendable {
    case success
    case warning
    case failure
  }

  let id: String
  let title: String
  let summary: String
  let outcome: Outcome
  let messages: [String]
  let recordedAt: Date
}

extension DashboardReviewActionAuditBackfillEntry.Outcome {
  var auditOutcome: String {
    switch self {
    case .success:
      "success"
    case .warning:
      "warning"
    case .failure:
      "failure"
    }
  }

  var auditSeverity: String {
    switch self {
    case .success:
      "info"
    case .warning:
      "warning"
    case .failure:
      "error"
    }
  }
}

public struct HarnessMonitorAuditEventsRequest: Codable, Equatable, Sendable {
  public var limit: Int?
  public var before: String?
  public var dateRange: HarnessMonitorAuditDateRange?
  public var sources: [String]
  public var categories: [String]
  public var severities: [String]
  public var outcomes: [String]
  public var actionKeys: [String]
  public var subject: String?
  public var searchText: String?

  public init(
    limit: Int? = nil,
    before: String? = nil,
    dateRange: HarnessMonitorAuditDateRange? = nil,
    sources: [String] = [],
    categories: [String] = [],
    severities: [String] = [],
    outcomes: [String] = [],
    actionKeys: [String] = [],
    subject: String? = nil,
    searchText: String? = nil
  ) {
    self.limit = limit
    self.before = before
    self.dateRange = dateRange
    self.sources = sources
    self.categories = categories
    self.severities = severities
    self.outcomes = outcomes
    self.actionKeys = actionKeys
    self.subject = subject
    self.searchText = searchText
  }
}

public struct HarnessMonitorAuditEventsResponse: Codable, Equatable, Sendable {
  public var events: [HarnessMonitorAuditEvent]
  public var nextCursor: String?
  public var hasOlder: Bool

  public init(
    events: [HarnessMonitorAuditEvent] = [],
    nextCursor: String? = nil,
    hasOlder: Bool = false
  ) {
    self.events = events
    self.nextCursor = nextCursor
    self.hasOlder = hasOlder
  }
}
