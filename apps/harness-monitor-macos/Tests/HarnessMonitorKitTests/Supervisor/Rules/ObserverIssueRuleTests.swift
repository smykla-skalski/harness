import Foundation
import XCTest

@testable import HarnessMonitorKit

/// TDD cover for `ObserverIssueRule` (source plan Task 14).
/// Trigger contract: at least `minCount` observer issues with severity ≥ `minSeverity` whose
/// `firstSeen` falls inside the last `issueWindow` seconds emit one cautious `.queueDecision`
/// action per session that bundles the related issue codes/ids into `contextJSON`.
final class ObserverIssueRuleTests: XCTestCase {
  private let now = Date.fixed

  // MARK: - Trigger boundary

  func test_emitsDecisionAtBoundary_whenExactlyMinCountIssuesFall_inWindow() async {
    let rule = ObserverIssueRule()
    let snapshot = makeSnapshot(
      sessionID: "s1",
      issues: [
        makeIssue(id: "i1", code: "obs.slow_tool", severity: "warn", firstSeenOffset: -30),
        makeIssue(id: "i2", code: "obs.retry_storm", severity: "warn", firstSeenOffset: -60),
        makeIssue(id: "i3", code: "obs.stall", severity: "warn", firstSeenOffset: -120),
      ]
    )

    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: makeContext(parameters: [:])
    )

    XCTAssertEqual(actions.count, 1)
    guard case .queueDecision(let payload) = actions.first else {
      XCTFail("expected queueDecision action, got \(String(describing: actions.first))")
      return
    }
    XCTAssertEqual(payload.ruleID, "observer-issue-escalation")
    XCTAssertEqual(payload.sessionID, "s1")
    XCTAssertEqual(payload.severity, .warn)
  }

  func test_doesNotEmitDecision_whenCountIsBelowMin() async {
    let rule = ObserverIssueRule()
    let snapshot = makeSnapshot(
      sessionID: "s1",
      issues: [
        makeIssue(id: "i1", code: "obs.slow_tool", severity: "warn", firstSeenOffset: -30),
        makeIssue(id: "i2", code: "obs.retry_storm", severity: "warn", firstSeenOffset: -60),
      ]
    )

    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: makeContext(parameters: [:])
    )

    XCTAssertTrue(actions.isEmpty)
  }

  func test_doesNotEmit_whenIssuesAreOutsideWindow() async {
    let rule = ObserverIssueRule()
    let snapshot = makeSnapshot(
      sessionID: "s1",
      issues: [
        makeIssue(id: "i1", code: "obs.slow_tool", severity: "warn", firstSeenOffset: -30),
        makeIssue(id: "i2", code: "obs.retry_storm", severity: "warn", firstSeenOffset: -60),
        makeIssue(id: "i3", code: "obs.old", severity: "warn", firstSeenOffset: -3_600),
      ]
    )

    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: makeContext(parameters: [:])
    )

    XCTAssertTrue(actions.isEmpty)
  }

  // MARK: - contextJSON bundle

  func test_contextJSON_containsAllRelatedIssueIdsAndCodes() async throws {
    let rule = ObserverIssueRule()
    let snapshot = makeSnapshot(
      sessionID: "s-alpha",
      issues: [
        makeIssue(id: "i1", code: "obs.slow_tool", severity: "warn", firstSeenOffset: -10),
        makeIssue(
          id: "i2",
          code: "obs.retry_storm",
          severity: "needsUser",
          firstSeenOffset: -20
        ),
        makeIssue(id: "i3", code: "obs.panic", severity: "critical", firstSeenOffset: -30),
      ]
    )

    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: makeContext(parameters: [:])
    )

    guard case .queueDecision(let payload) = actions.first else {
      XCTFail("expected queueDecision")
      return
    }
    let data = Data(payload.contextJSON.utf8)
    let bundle = try JSONDecoder().decode(ObserverBundle.self, from: data)

    XCTAssertEqual(bundle.sessionID, "s-alpha")
    XCTAssertEqual(bundle.issues.map(\.id).sorted(), ["i1", "i2", "i3"])
    XCTAssertEqual(
      bundle.issues.map(\.code).sorted(),
      ["obs.panic", "obs.retry_storm", "obs.slow_tool"]
    )
    // severity of the emitted decision lifts to the max-observed severity in the bundle
    XCTAssertEqual(payload.severity, .critical)
  }

  // MARK: - minSeverity filter

  func test_ignoresIssuesBelowMinSeverity() async {
    let rule = ObserverIssueRule()
    let snapshot = makeSnapshot(
      sessionID: "s1",
      issues: [
        makeIssue(id: "i1", code: "obs.hint", severity: "info", firstSeenOffset: -10),
        makeIssue(id: "i2", code: "obs.hint", severity: "info", firstSeenOffset: -20),
        makeIssue(id: "i3", code: "obs.warn", severity: "warn", firstSeenOffset: -30),
        makeIssue(id: "i4", code: "obs.warn", severity: "warn", firstSeenOffset: -40),
      ]
    )

    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: makeContext(parameters: [:])
    )

    XCTAssertTrue(
      actions.isEmpty,
      "only 2 issues are ≥ warn; below the minCount=3 trigger"
    )
  }

  func test_respectsMinSeverityOverride_raisingThresholdToCritical() async {
    let rule = ObserverIssueRule()
    let snapshot = makeSnapshot(
      sessionID: "s1",
      issues: [
        makeIssue(id: "i1", code: "obs.warn", severity: "warn", firstSeenOffset: -10),
        makeIssue(id: "i2", code: "obs.warn", severity: "warn", firstSeenOffset: -20),
        makeIssue(id: "i3", code: "obs.warn", severity: "warn", firstSeenOffset: -30),
      ]
    )

    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: makeContext(parameters: ["minSeverity": "critical"])
    )

    XCTAssertTrue(actions.isEmpty)
  }

  func test_respectsMinCountOverride() async {
    let rule = ObserverIssueRule()
    let snapshot = makeSnapshot(
      sessionID: "s1",
      issues: [
        makeIssue(id: "i1", code: "obs.warn", severity: "warn", firstSeenOffset: -10),
        makeIssue(id: "i2", code: "obs.warn", severity: "warn", firstSeenOffset: -20),
      ]
    )

    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: makeContext(parameters: ["minCount": "2"])
    )

    XCTAssertEqual(actions.count, 1)
  }

  func test_respectsIssueWindowOverride_shrinkingWindow() async {
    let rule = ObserverIssueRule()
    let snapshot = makeSnapshot(
      sessionID: "s1",
      issues: [
        makeIssue(id: "i1", code: "obs.warn", severity: "warn", firstSeenOffset: -10),
        makeIssue(id: "i2", code: "obs.warn", severity: "warn", firstSeenOffset: -20),
        makeIssue(id: "i3", code: "obs.warn", severity: "warn", firstSeenOffset: -120),
      ]
    )

    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: makeContext(parameters: ["issueWindow": "60"])
    )

    XCTAssertTrue(actions.isEmpty)
  }

  // MARK: - Metadata

  func test_ruleMetadataMatchesFrozenContract() {
    let rule = ObserverIssueRule()
    XCTAssertEqual(rule.id, "observer-issue-escalation")
    XCTAssertEqual(rule.name, "Observer Issue Escalation")
    XCTAssertEqual(rule.defaultBehavior(for: "queueDecision"), .cautious)
  }

  func test_parameterSchemaExposesAllThreeFields() {
    let keys = ObserverIssueRule().parameters.fields.map(\.key)
    XCTAssertEqual(Set(keys), ["issueWindow", "minCount", "minSeverity"])
  }

  // MARK: - Per-session fan-out

  func test_emitsOneDecisionPerTriggeringSession() async {
    let rule = ObserverIssueRule()
    let snapshot = SessionsSnapshot(
      id: "snap-multi",
      createdAt: now,
      hash: "h",
      sessions: [
        SessionSnapshot(
          id: "s1",
          title: nil,
          agents: [],
          tasks: [],
          timelineDensityLastMinute: 0,
          observerIssues: [
            makeIssue(id: "a1", code: "obs.warn", severity: "warn", firstSeenOffset: -10),
            makeIssue(id: "a2", code: "obs.warn", severity: "warn", firstSeenOffset: -20),
            makeIssue(id: "a3", code: "obs.warn", severity: "warn", firstSeenOffset: -30),
          ],
          pendingCodexApprovals: []
        ),
        SessionSnapshot(
          id: "s2",
          title: nil,
          agents: [],
          tasks: [],
          timelineDensityLastMinute: 0,
          observerIssues: [
            makeIssue(id: "b1", code: "obs.warn", severity: "warn", firstSeenOffset: -10),
            makeIssue(id: "b2", code: "obs.warn", severity: "warn", firstSeenOffset: -20),
            makeIssue(id: "b3", code: "obs.warn", severity: "warn", firstSeenOffset: -30),
          ],
          pendingCodexApprovals: []
        ),
      ],
      connection: ConnectionSnapshot(kind: "connected", lastMessageAt: now, reconnectAttempt: 0)
    )

    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: makeContext(parameters: [:])
    )

    let sessions: [String] = actions.compactMap {
      if case .queueDecision(let payload) = $0 { return payload.sessionID }
      return nil
    }
    XCTAssertEqual(Set(sessions), ["s1", "s2"])
    XCTAssertEqual(actions.count, 2)
  }

  // MARK: - Helpers

  private func makeIssue(
    id: String,
    code: String,
    severity: String,
    firstSeenOffset: TimeInterval
  ) -> ObserverIssueSnapshot {
    ObserverIssueSnapshot(
      id: id,
      severityRaw: severity,
      code: code,
      firstSeen: now.addingTimeInterval(firstSeenOffset),
      count: 1
    )
  }

  private func makeSnapshot(
    sessionID: String,
    issues: [ObserverIssueSnapshot]
  ) -> SessionsSnapshot {
    SessionsSnapshot(
      id: "snap-\(sessionID)",
      createdAt: now,
      hash: "h",
      sessions: [
        SessionSnapshot(
          id: sessionID,
          title: nil,
          agents: [],
          tasks: [],
          timelineDensityLastMinute: 0,
          observerIssues: issues,
          pendingCodexApprovals: []
        )
      ],
      connection: ConnectionSnapshot(kind: "connected", lastMessageAt: now, reconnectAttempt: 0)
    )
  }

  private func makeContext(parameters: [String: String]) -> PolicyContext {
    PolicyContext(
      now: now,
      lastFiredAt: nil,
      recentActionKeys: [],
      parameters: PolicyParameterValues(raw: parameters),
      history: PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    )
  }

  private struct ObserverBundle: Decodable {
    let sessionID: String
    let issues: [Entry]

    struct Entry: Decodable {
      let id: String
      let code: String
      let severity: String
      let firstSeen: Date
      let count: Int
    }
  }
}
