import XCTest

@testable import HarnessMonitorKit

final class LoggingPolicyObserverTests: XCTestCase {
  private func makeSnapshot(id: String = "snap-1") -> SessionsSnapshot {
    SessionsSnapshot(
      id: id,
      createdAt: .fixed,
      hash: "deadbeef",
      sessions: [],
      connection: ConnectionSnapshot(
        kind: "connected",
        lastMessageAt: .fixed,
        reconnectAttempt: 0
      )
    )
  }

  private func makeAction(id: String = "log-1", ruleID: String = "stuck-agent") -> PolicyAction {
    .logEvent(
      PolicyAction.LogPayload(
        id: id,
        ruleID: ruleID,
        snapshotID: "snap-1",
        message: "observed"
      )
    )
  }

  func test_willTickEmitsStructuredEntry() async {
    let sink = RecordingSupervisorLogSink()
    let observer = LoggingPolicyObserver(sink: sink)

    await observer.willTick(makeSnapshot(id: "snap-7"))

    let entries = sink.snapshot()
    XCTAssertEqual(entries.count, 1)
    let entry = try? XCTUnwrap(entries.first)
    XCTAssertEqual(entry?.event, "willTick")
    XCTAssertEqual(entry?.fields["tickID"], "snap-7")
    XCTAssertEqual(entry?.fields["sessionsHash"], "deadbeef")
  }

  func test_didEvaluateEmitsRuleAndActionCount() async {
    let sink = RecordingSupervisorLogSink()
    let observer = LoggingPolicyObserver(sink: sink)
    let rule = StuckAgentRule()

    await observer.didEvaluate(rule: rule, actions: [makeAction(id: "a"), makeAction(id: "b")])

    let entries = sink.snapshot()
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.event, "didEvaluate")
    XCTAssertEqual(entries.first?.fields["ruleID"], "stuck-agent")
    XCTAssertEqual(entries.first?.fields["actionCount"], "2")
  }

  func test_didExecuteEmitsActionKeyAndOutcome() async {
    let sink = RecordingSupervisorLogSink()
    let observer = LoggingPolicyObserver(sink: sink)
    let action = makeAction(id: "log-42", ruleID: "idle-session")

    await observer.didExecute(
      action: action,
      outcome: .executed(actionKey: action.actionKey)
    )

    let entries = sink.snapshot()
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.event, "didExecute")
    XCTAssertEqual(entries.first?.fields["actionKey"], action.actionKey)
    XCTAssertEqual(entries.first?.fields["outcome"], "executed")
    XCTAssertEqual(entries.first?.fields["ruleID"], "idle-session")
  }

  func test_didExecuteFailedOutcomeCarriesErrorField() async {
    let sink = RecordingSupervisorLogSink()
    let observer = LoggingPolicyObserver(sink: sink)
    let action = makeAction()

    await observer.didExecute(
      action: action,
      outcome: .failed(actionKey: action.actionKey, error: "boom")
    )

    let entries = sink.snapshot()
    XCTAssertEqual(entries.first?.fields["outcome"], "failed")
    XCTAssertEqual(entries.first?.fields["error"], "boom")
  }

  func test_didExecuteFailedOutcomeRedactsRawErrorDetails() async {
    let sink = RecordingSupervisorLogSink()
    let observer = LoggingPolicyObserver(sink: sink)
    let action = makeAction()

    await observer.didExecute(
      action: action,
      outcome: .failed(actionKey: action.actionKey, error: "token=super-secret-value")
    )

    let redacted = sink.snapshot().first?.fields["error"]
    XCTAssertNotNil(redacted)
    XCTAssertFalse(redacted?.contains("super-secret-value") ?? false)
  }

  func test_proposeConfigSuggestionReturnsEmpty() async {
    let observer = LoggingPolicyObserver(sink: RecordingSupervisorLogSink())
    let window = PolicyHistoryWindow(recentEvents: [], recentDecisions: [])

    let suggestions = await observer.proposeConfigSuggestion(history: window)

    XCTAssertTrue(suggestions.isEmpty)
  }

  func test_proposeConfigSuggestionDoesNotLog() async {
    let sink = RecordingSupervisorLogSink()
    let observer = LoggingPolicyObserver(sink: sink)

    _ = await observer.proposeConfigSuggestion(
      history: PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    )

    XCTAssertTrue(sink.snapshot().isEmpty)
  }

  func test_defaultInitUsesOSLogSink() {
    // Smoke: the default initializer must be available so registry code can instantiate the
    // observer without plumbing a sink. The OSLog-backed sink is private; we assert the
    // instance exists.
    _ = LoggingPolicyObserver()
  }
}

private final class RecordingSupervisorLogSink: SupervisorLogSink, @unchecked Sendable {
  struct Entry: Sendable {
    let event: String
    let fields: [String: String]
  }

  private let lock = NSLock()
  private var entries: [Entry] = []

  func record(event: String, fields: [String: String]) {
    lock.lock()
    defer { lock.unlock() }
    entries.append(Entry(event: event, fields: fields))
  }

  func snapshot() -> [Entry] {
    lock.lock()
    defer { lock.unlock() }
    return entries
  }
}
