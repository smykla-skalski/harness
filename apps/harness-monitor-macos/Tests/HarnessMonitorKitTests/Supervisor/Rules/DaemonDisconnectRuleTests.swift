import XCTest

@testable import HarnessMonitorKit

final class DaemonDisconnectRuleTests: XCTestCase {
  // MARK: - Helpers

  private func makeSnapshot(
    kind: String,
    lastMessageAt: Date?,
    createdAt: Date = .fixed
  ) -> SessionsSnapshot {
    SessionsSnapshot(
      id: "snap-\(Int(createdAt.timeIntervalSince1970))",
      createdAt: createdAt,
      hash: "hash",
      sessions: [],
      connection: ConnectionSnapshot(
        kind: kind,
        lastMessageAt: lastMessageAt,
        reconnectAttempt: 0
      )
    )
  }

  private func makeContext(
    now: Date,
    parameters: [String: String] = [:],
    recentActionKeys: Set<String> = []
  ) -> PolicyContext {
    PolicyContext(
      now: now,
      lastFiredAt: nil,
      recentActionKeys: recentActionKeys,
      parameters: PolicyParameterValues(raw: parameters),
      history: PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    )
  }

  // MARK: - No-op paths

  func test_connectedSnapshot_emitsNoAction() async {
    let rule = DaemonDisconnectRule()
    let snapshot = makeSnapshot(kind: "connected", lastMessageAt: .fixed)
    let context = makeContext(now: .fixed)

    let actions = await rule.evaluate(snapshot: snapshot, context: context)

    XCTAssertTrue(actions.isEmpty)
  }

  func test_disconnectedWithinGrace_emitsNoAction() async {
    let rule = DaemonDisconnectRule()
    let disconnectedSince = Date.fixed
    // 10s < default 15s grace
    let now = disconnectedSince.addingTimeInterval(10)
    let snapshot = makeSnapshot(
      kind: "disconnected",
      lastMessageAt: disconnectedSince,
      createdAt: now
    )
    let context = makeContext(now: now)

    let actions = await rule.evaluate(snapshot: snapshot, context: context)

    XCTAssertTrue(actions.isEmpty)
  }

  // MARK: - Notify after grace

  func test_disconnectedPastGrace_emitsNotifyOnly() async {
    let rule = DaemonDisconnectRule()
    let disconnectedSince = Date.fixed
    // 20s > default 15s grace, < 60s escalation
    let now = disconnectedSince.addingTimeInterval(20)
    let snapshot = makeSnapshot(
      kind: "disconnected",
      lastMessageAt: disconnectedSince,
      createdAt: now
    )
    let context = makeContext(now: now)

    let actions = await rule.evaluate(snapshot: snapshot, context: context)

    XCTAssertEqual(actions.count, 1)
    guard case .notifyOnly(let payload) = actions[0] else {
      XCTFail("expected notifyOnly action; got \(actions)")
      return
    }
    XCTAssertEqual(payload.ruleID, rule.id)
    XCTAssertEqual(payload.severity, .warn)
    XCTAssertEqual(payload.snapshotID, snapshot.id)
    XCTAssertFalse(payload.summary.isEmpty)
  }

  func test_disconnectedPastGrace_respectsCustomGraceParameter() async {
    let rule = DaemonDisconnectRule()
    let disconnectedSince = Date.fixed
    // 5s, default grace is 15s — would not trigger. With grace=3, it triggers.
    let now = disconnectedSince.addingTimeInterval(5)
    let snapshot = makeSnapshot(
      kind: "disconnected",
      lastMessageAt: disconnectedSince,
      createdAt: now
    )
    let context = makeContext(
      now: now,
      parameters: [
        "disconnectGraceSeconds": "3",
        "disconnectEscalationSeconds": "120",
      ]
    )

    let actions = await rule.evaluate(snapshot: snapshot, context: context)

    XCTAssertEqual(actions.count, 1)
    guard case .notifyOnly = actions[0] else {
      XCTFail("expected notifyOnly action for shortened grace")
      return
    }
  }

  // MARK: - Critical decision after escalation

  func test_disconnectedPastEscalation_emitsCriticalQueueDecision() async {
    let rule = DaemonDisconnectRule()
    let disconnectedSince = Date.fixed
    // 90s > default 60s escalation threshold
    let now = disconnectedSince.addingTimeInterval(90)
    let snapshot = makeSnapshot(
      kind: "disconnected",
      lastMessageAt: disconnectedSince,
      createdAt: now
    )
    let context = makeContext(now: now)

    let actions = await rule.evaluate(snapshot: snapshot, context: context)

    XCTAssertEqual(actions.count, 1)
    guard case .queueDecision(let payload) = actions[0] else {
      XCTFail("expected queueDecision action; got \(actions)")
      return
    }
    XCTAssertEqual(payload.ruleID, rule.id)
    XCTAssertEqual(payload.severity, .critical)
    XCTAssertFalse(payload.summary.isEmpty)
    XCTAssertFalse(payload.id.isEmpty)
  }

  func test_disconnectedPastEscalation_decisionIdIsStablePerEpisode() async {
    let rule = DaemonDisconnectRule()
    let disconnectedSince = Date.fixed
    let firstTick = disconnectedSince.addingTimeInterval(70)
    let secondTick = disconnectedSince.addingTimeInterval(95)

    let firstSnapshot = makeSnapshot(
      kind: "disconnected",
      lastMessageAt: disconnectedSince,
      createdAt: firstTick
    )
    let secondSnapshot = makeSnapshot(
      kind: "disconnected",
      lastMessageAt: disconnectedSince,
      createdAt: secondTick
    )

    let firstActions = await rule.evaluate(
      snapshot: firstSnapshot,
      context: makeContext(now: firstTick)
    )
    let secondActions = await rule.evaluate(
      snapshot: secondSnapshot,
      context: makeContext(now: secondTick)
    )

    guard
      case .queueDecision(let first) = firstActions.first,
      case .queueDecision(let second) = secondActions.first
    else {
      XCTFail("expected both ticks to emit queueDecision")
      return
    }
    XCTAssertEqual(
      first.id,
      second.id,
      "decision id should be stable across ticks within the same disconnect episode"
    )
  }

  func test_disconnectedPastEscalation_dedupesViaRecentActionKeys() async {
    let rule = DaemonDisconnectRule()
    let disconnectedSince = Date.fixed
    let now = disconnectedSince.addingTimeInterval(90)
    let snapshot = makeSnapshot(
      kind: "disconnected",
      lastMessageAt: disconnectedSince,
      createdAt: now
    )
    // Simulate prior tick's decision already on record.
    let firstContext = makeContext(now: now)
    let firstActions = await rule.evaluate(snapshot: snapshot, context: firstContext)
    guard let firstKey = firstActions.first?.actionKey else {
      XCTFail("expected initial action")
      return
    }

    let followUpContext = makeContext(now: now, recentActionKeys: [firstKey])
    let followUpActions = await rule.evaluate(
      snapshot: snapshot,
      context: followUpContext
    )

    XCTAssertTrue(followUpActions.isEmpty, "rule must not re-emit the same decision key")
  }

  // MARK: - Nil last-message anchor

  func test_disconnectedWithNilLastMessage_usesSnapshotCreatedAsAnchor() async {
    let rule = DaemonDisconnectRule()
    // With lastMessageAt nil, the snapshot createdAt anchors the episode. `now` is
    // well past the default escalation threshold so the rule must still fire.
    let createdAt = Date.fixed
    let now = createdAt.addingTimeInterval(120)
    let snapshot = makeSnapshot(
      kind: "disconnected",
      lastMessageAt: nil,
      createdAt: createdAt
    )
    let context = makeContext(now: now)

    let actions = await rule.evaluate(snapshot: snapshot, context: context)

    XCTAssertEqual(actions.count, 1)
    guard case .queueDecision(let payload) = actions[0] else {
      XCTFail("expected queueDecision with nil lastMessageAt anchor")
      return
    }
    XCTAssertEqual(payload.severity, .critical)
  }

  // MARK: - Rule metadata

  func test_parametersSchemaDeclaresThresholds() {
    let rule = DaemonDisconnectRule()
    let keys = rule.parameters.fields.map(\.key)
    XCTAssertTrue(keys.contains("disconnectGraceSeconds"))
    XCTAssertTrue(keys.contains("disconnectEscalationSeconds"))
  }

  func test_defaultBehaviorIsAggressive() {
    let rule = DaemonDisconnectRule()
    XCTAssertEqual(rule.defaultBehavior(for: "any"), .aggressive)
  }
}
