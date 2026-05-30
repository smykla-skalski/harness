import Foundation

/// Aggregate run counts for a policy history response. Mirrors the daemon's
/// `ReviewsPolicyRunMetrics` so the Monitor can render totals without
/// re-deriving them from the run list.
public struct ReviewsPolicyRunMetrics: Codable, Equatable, Sendable {
  public var total: Int
  public var running: Int
  public var waiting: Int
  public var completed: Int
  public var failed: Int
  public var cancelled: Int
  public var byTrigger: [String: Int]

  public init(
    total: Int = 0,
    running: Int = 0,
    waiting: Int = 0,
    completed: Int = 0,
    failed: Int = 0,
    cancelled: Int = 0,
    byTrigger: [String: Int] = [:]
  ) {
    self.total = total
    self.running = running
    self.waiting = waiting
    self.completed = completed
    self.failed = failed
    self.cancelled = cancelled
    self.byTrigger = byTrigger
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
    running = try container.decodeIfPresent(Int.self, forKey: .running) ?? 0
    waiting = try container.decodeIfPresent(Int.self, forKey: .waiting) ?? 0
    completed = try container.decodeIfPresent(Int.self, forKey: .completed) ?? 0
    failed = try container.decodeIfPresent(Int.self, forKey: .failed) ?? 0
    cancelled = try container.decodeIfPresent(Int.self, forKey: .cancelled) ?? 0
    byTrigger = try container.decodeIfPresent([String: Int].self, forKey: .byTrigger) ?? [:]
  }
}

/// A single flattened entry in a policy run timeline export. Mirrors the
/// daemon's `ReviewsPolicyTimelineEntry`.
public struct ReviewsPolicyTimelineEntry: Codable, Equatable, Sendable {
  public var recordedAt: String
  public var runID: String
  public var event: String

  public init(recordedAt: String, runID: String, event: String) {
    self.recordedAt = recordedAt
    self.runID = runID
    self.event = event
  }

  enum CodingKeys: String, CodingKey {
    case recordedAt
    case runID = "runId"
    case event
  }
}

/// Request the run history for a policy workflow scoped to a review subject.
public struct ReviewsPolicyHistoryRequest: Codable, Equatable, Sendable {
  public var workflowID: String
  public var subject: ReviewsPolicySubject

  public init(
    workflowID: String = ReviewsPolicyDefaults.workflowID,
    subject: ReviewsPolicySubject
  ) {
    self.workflowID = workflowID
    self.subject = subject
  }

  enum CodingKeys: String, CodingKey {
    case workflowID = "workflowId"
    case subject
  }
}

/// Run list, aggregate metrics, and timeline export returned by the daemon
/// policy history endpoint. The daemon omits empty `runs`/`timeline` and a
/// default `metrics`, so those decode to empty values when absent.
public struct ReviewsPolicyHistoryResponse: Codable, Equatable, Sendable {
  public var workflowID: String
  public var subject: ReviewsPolicySubject
  public var runs: [ReviewsPolicyRunResponse]
  public var metrics: ReviewsPolicyRunMetrics
  public var timeline: [ReviewsPolicyTimelineEntry]

  public init(
    workflowID: String = ReviewsPolicyDefaults.workflowID,
    subject: ReviewsPolicySubject,
    runs: [ReviewsPolicyRunResponse] = [],
    metrics: ReviewsPolicyRunMetrics = ReviewsPolicyRunMetrics(),
    timeline: [ReviewsPolicyTimelineEntry] = []
  ) {
    self.workflowID = workflowID
    self.subject = subject
    self.runs = runs
    self.metrics = metrics
    self.timeline = timeline
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    workflowID =
      try container.decodeIfPresent(String.self, forKey: .workflowID)
      ?? ReviewsPolicyDefaults.workflowID
    subject = try container.decode(ReviewsPolicySubject.self, forKey: .subject)
    runs = try container.decodeIfPresent([ReviewsPolicyRunResponse].self, forKey: .runs) ?? []
    metrics =
      try container.decodeIfPresent(ReviewsPolicyRunMetrics.self, forKey: .metrics)
      ?? ReviewsPolicyRunMetrics()
    timeline =
      try container.decodeIfPresent([ReviewsPolicyTimelineEntry].self, forKey: .timeline) ?? []
  }

  enum CodingKeys: String, CodingKey {
    case workflowID = "workflowId"
    case subject
    case runs
    case metrics
    case timeline
  }
}
