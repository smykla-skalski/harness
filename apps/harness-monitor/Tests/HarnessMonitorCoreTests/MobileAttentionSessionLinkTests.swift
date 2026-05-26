import Foundation
import HarnessMonitorCore
import XCTest

final class MobileAttentionSessionLinkTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func attention(kind: MobileAttentionKind, sessionID: String?) -> MobileAttentionItem {
    MobileAttentionItem(
      id: "attn-\(kind.rawValue)-\(sessionID ?? "none")",
      stationID: "station-a",
      kind: kind,
      severity: .warning,
      title: "Attention",
      subtitle: "x",
      updatedAt: now,
      target: sessionID.map {
        MobileCommandTarget(stationID: "station-a", sessionID: $0, targetRevision: 1)
      }
    )
  }

  func testBlockedAgentResolvesMatchingSessionID() {
    let session = mobileSession("s1", stationID: "station-a", now: now)
    let item = attention(kind: .blockedAgent, sessionID: "s1")
    XCTAssertEqual(item.navigableSessionID(in: [session]), "s1")
  }

  func testACPDecisionResolvesMatchingSessionID() {
    let session = mobileSession("s1", stationID: "station-a", now: now)
    let item = attention(kind: .acpDecision, sessionID: "s1")
    XCTAssertEqual(item.navigableSessionID(in: [session]), "s1")
  }

  func testMissingSessionReturnsNil() {
    let session = mobileSession("s1", stationID: "station-a", now: now)
    let item = attention(kind: .blockedAgent, sessionID: "ghost")
    XCTAssertNil(item.navigableSessionID(in: [session]))
  }

  func testNonSessionKindReturnsNil() {
    let session = mobileSession("s1", stationID: "station-a", now: now)
    let item = attention(kind: .pullRequest, sessionID: "s1")
    XCTAssertNil(item.navigableSessionID(in: [session]))
  }
}
