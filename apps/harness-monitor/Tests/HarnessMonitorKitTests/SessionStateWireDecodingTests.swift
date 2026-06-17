import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for the session-state foundation leaf, generated from
/// src/session/types/state.rs. SessionStatus is the adopted closed enum - the hand
/// decl was replaced by the generated form, its `title` kept in an extension - so
/// these prove the generated form decodes the 5 lifecycle cases and stays closed
/// (rejects an unrecognized status, matching the closed Rust enum). SessionMetricsWire
/// mirrors the u32 rollup counts the hand SessionMetrics decodes as Int, including
/// the lenient default-to-zero for absent counts. Both are SessionSummary deps
/// pinned ahead of the summaries migration.
@Suite("Session state wire cluster")
struct SessionStateWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes SessionStatus from each snake_case wire string")
  func decodesSessionStatus() throws {
    #expect(try decodeStatus("awaiting_leader") == .awaitingLeader)
    #expect(try decodeStatus("active") == .active)
    #expect(try decodeStatus("paused") == .paused)
    #expect(try decodeStatus("leaderless_degraded") == .leaderlessDegraded)
    #expect(try decodeStatus("ended") == .ended)
  }

  @Test("rejects an unrecognized SessionStatus - it is a closed enum")
  func rejectsUnknownSessionStatus() {
    #expect(throws: DecodingError.self) {
      try decodeStatus("hibernating")
    }
  }

  @Test("the adopted SessionStatus keeps its title in an extension")
  func sessionStatusTitleSurvivesAdoption() {
    #expect(SessionStatus.leaderlessDegraded.title == "Leaderless")
    #expect(SessionStatus.awaitingLeader.title == "Awaiting Leader")
  }

  @Test("decodes SessionMetricsWire counts from the daemon snake keys")
  func decodesSessionMetrics() throws {
    let metrics = try decoder.decode(
      SessionMetricsWire.self, from: Data(sessionMetricsPayloadFixture.utf8)
    )
    #expect(metrics.agentCount == 4)
    #expect(metrics.activeAgentCount == 2)
    #expect(metrics.openTaskCount == 7)
    #expect(metrics.completedTaskCount == 11)
  }

  @Test("defaults absent SessionMetricsWire counts to zero")
  func defaultsAbsentMetricsToZero() throws {
    let metrics = try decoder.decode(SessionMetricsWire.self, from: Data("{}".utf8))
    #expect(metrics.agentCount == 0)
    #expect(metrics.inReviewTaskCount == 0)
    #expect(metrics.completedTaskCount == 0)
  }

  private func decodeStatus(_ value: String) throws -> SessionStatus {
    try decoder.decode(SessionStatus.self, from: Data("\"\(value)\"".utf8))
  }
}

private let sessionMetricsPayloadFixture = """
  {
    "agent_count": 4,
    "active_agent_count": 2,
    "idle_agent_count": 1,
    "awaiting_review_agent_count": 1,
    "open_task_count": 7,
    "in_progress_task_count": 3,
    "awaiting_review_task_count": 2,
    "in_review_task_count": 1,
    "arbitration_task_count": 0,
    "blocked_task_count": 1,
    "completed_task_count": 11
  }
  """
