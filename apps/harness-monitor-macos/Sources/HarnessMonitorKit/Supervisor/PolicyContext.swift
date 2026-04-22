import Foundation

/// Per-rule context handed into `PolicyRule.evaluate`. Public field list is part of the
/// Phase 1 signature freeze.
public struct PolicyContext: Sendable {
  public let now: Date
  public let lastFiredAt: Date?
  public let recentActionKeys: Set<String>
  public let parameters: PolicyParameterValues
  public let history: PolicyHistoryWindow

  public init(
    now: Date,
    lastFiredAt: Date?,
    recentActionKeys: Set<String>,
    parameters: PolicyParameterValues,
    history: PolicyHistoryWindow
  ) {
    self.now = now
    self.lastFiredAt = lastFiredAt
    self.recentActionKeys = recentActionKeys
    self.parameters = parameters
    self.history = history
  }

  public static let empty = Self(
    now: Date(timeIntervalSince1970: 0),
    lastFiredAt: nil,
    recentActionKeys: [],
    parameters: PolicyParameterValues(raw: [:]),
    history: PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
  )
}

public struct PolicyHistoryWindow: Sendable {
  public let recentEvents: [SupervisorEventSummary]
  public let recentDecisions: [DecisionSummary]

  public init(recentEvents: [SupervisorEventSummary], recentDecisions: [DecisionSummary]) {
    self.recentEvents = recentEvents
    self.recentDecisions = recentDecisions
  }
}

public struct PolicyParameterValues: Sendable {
  public let raw: [String: String]

  public init(raw: [String: String]) {
    self.raw = raw
  }

  public func string(_ key: String, default defaultValue: String) -> String {
    raw[key] ?? defaultValue
  }

  public func int(_ key: String, default defaultValue: Int) -> Int {
    raw[key].flatMap(Int.init) ?? defaultValue
  }

  public func seconds(_ key: String, default defaultValue: Int) -> Int {
    int(key, default: defaultValue)
  }
}

public struct SupervisorEventSummary: Sendable, Equatable, Hashable {
  public let id: String
  public let kind: String
  public let ruleID: String?
  public let createdAt: Date

  public init(id: String, kind: String, ruleID: String?, createdAt: Date) {
    self.id = id
    self.kind = kind
    self.ruleID = ruleID
    self.createdAt = createdAt
  }
}

public struct DecisionSummary: Sendable, Equatable, Hashable {
  public let id: String
  public let ruleID: String
  public let severity: DecisionSeverity
  public let createdAt: Date

  public init(id: String, ruleID: String, severity: DecisionSeverity, createdAt: Date) {
    self.id = id
    self.ruleID = ruleID
    self.severity = severity
    self.createdAt = createdAt
  }
}
