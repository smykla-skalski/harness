import Foundation
import XCTest

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

final class SessionTimelineEventFeatureRegistryTests: XCTestCase {
  func testDecisionFeatureHandlesLinkedDecisionEntry() {
    let entry = makeEntry(payload: .object(["decisionID": .string("d1")]))
    let feature = SessionTimelineEventFeatureRegistry.firstMatch(for: entry)
    XCTAssertNotNil(feature)
    XCTAssertTrue(feature is DecisionEventFeature)
  }

  func testDecisionFeatureHandlesAllKeyVariants() {
    for key in ["decisionID", "decisionId", "decision_id"] {
      let entry = makeEntry(payload: .object([key: .string("d1")]))
      XCTAssertNotNil(
        SessionTimelineEventFeatureRegistry.firstMatch(for: entry),
        "expected match for key \(key)"
      )
    }
  }

  func testRegistryReturnsNilForArbitraryEvent() {
    let entry = makeEntry(kind: "tool_result", payload: .null)
    XCTAssertNil(SessionTimelineEventFeatureRegistry.firstMatch(for: entry))
  }

  func testRegistryReturnsNilForNullPayload() {
    let entry = makeEntry(payload: .null)
    XCTAssertNil(SessionTimelineEventFeatureRegistry.firstMatch(for: entry))
  }

  func testSignalBeatsDecisionWhenBothCouldMatch() {
    // signal_acknowledged with a decisionID in payload — signal feature is first in registry
    let entry = makeEntry(
      kind: "signal_acknowledged",
      payload: .object(["signal_id": .string("sig-1"), "decisionID": .string("d1")])
    )
    let feature = SessionTimelineEventFeatureRegistry.firstMatch(for: entry)
    XCTAssertTrue(
      feature is SignalTimelineEventFeature,
      "signal feature must win over decision feature when both predicates match"
    )
  }

  func testDecisionFeatureActionsEmptyWhenNoDecision() {
    let node = SessionTimelineNode(
      identity: .entry("e1"),
      kind: .event,
      timestamp: .distantPast,
      rawTimestamp: nil,
      sourceLabel: "tool_result",
      title: "result",
      detail: nil,
      eventTone: nil,
      decision: nil
    )
    XCTAssertEqual(DecisionEventFeature().actions(for: node, ctx: .empty), [])
  }

  private func makeEntry(
    kind: String = "conversation_event",
    payload: JSONValue
  ) -> TimelineEntry {
    TimelineEntry(
      entryId: UUID().uuidString,
      recordedAt: "2026-01-01T00:00:00Z",
      kind: kind,
      sessionId: "s1",
      agentId: nil,
      taskId: nil,
      summary: "event",
      payload: payload
    )
  }
}
