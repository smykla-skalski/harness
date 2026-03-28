import Foundation
import XCTest

@testable import HarnessMonitorKit

private struct ObserverSummaryPayload: Encodable {
  let observeId: String
  let lastScanTime: String
  let openIssueCount: Int
  let mutedCodeCount: Int
  let activeWorkerCount: Int
  let openIssues: [ObserverIssuePayload]?
  let mutedCodes: [String]?
  let activeWorkers: [ObserverWorkerPayload]?
}

private struct ObserverIssuePayload: Encodable {
  let issueId: String
  let code: String
  let summary: String
  let severity: String
  let fingerprint: String?
  let firstSeenLine: Int?
  let lastSeenLine: Int?
  let occurrenceCount: Int?
  let fixSafety: String?
  let evidenceExcerpt: String?
}

private struct ObserverWorkerPayload: Encodable {
  let issueId: String
  let targetFile: String
  let startedAt: String
  let agentId: String?
  let runtime: String?
}

final class ObserverSummaryTests: XCTestCase {
  func testObserverSummaryDecodesWithoutRichDetail() throws {
    let payload = ObserverSummaryPayload(
      observeId: "observe-sess-1",
      lastScanTime: "2026-03-28T14:17:45Z",
      openIssueCount: 3,
      mutedCodeCount: 1,
      activeWorkerCount: 2,
      openIssues: nil,
      mutedCodes: nil,
      activeWorkers: nil
    )

    let summary = try decodeObserverSummary(from: payload)

    XCTAssertEqual(summary.observeId, "observe-sess-1")
    XCTAssertNil(summary.openIssues)
    XCTAssertNil(summary.mutedCodes)
    XCTAssertNil(summary.activeWorkers)
  }

  func testObserverSummaryDecodesRichDetail() throws {
    let payload = ObserverSummaryPayload(
      observeId: "observe-sess-1",
      lastScanTime: "2026-03-28T14:17:45Z",
      openIssueCount: 3,
      mutedCodeCount: 1,
      activeWorkerCount: 2,
      openIssues: [
        ObserverIssuePayload(
          issueId: "issue-1",
          code: "agent_stalled_progress",
          summary: "worker stalled",
          severity: "critical",
          fingerprint: "fp-1",
          firstSeenLine: 10,
          lastSeenLine: 14,
          occurrenceCount: 2,
          fixSafety: "triage_required",
          evidenceExcerpt: "No checkpoint for 12 minutes."
        )
      ],
      mutedCodes: ["agent_repeated_error"],
      activeWorkers: [
        ObserverWorkerPayload(
          issueId: "issue-1",
          targetFile: "src/daemon/timeline.rs",
          startedAt: "2026-03-28T14:16:30Z",
          agentId: "worker-codex",
          runtime: "codex"
        )
      ]
    )

    let summary = try decodeObserverSummary(from: payload)

    XCTAssertEqual(summary.openIssues?.count, 1)
    XCTAssertEqual(summary.openIssues?.first?.code, "agent_stalled_progress")
    XCTAssertEqual(summary.mutedCodes, ["agent_repeated_error"])
    XCTAssertEqual(summary.activeWorkers?.first?.agentId, "worker-codex")
  }

  func testPreviewObserverIncludesRichObserveDetail() throws {
    XCTAssertEqual(PreviewFixtures.observer.openIssues?.count, 3)
    XCTAssertEqual(PreviewFixtures.observer.mutedCodes, ["agent_repeated_error"])
    XCTAssertEqual(PreviewFixtures.observer.activeWorkers?.count, 2)
  }

  private func decodeObserverSummary(
    from payload: ObserverSummaryPayload
  ) throws -> ObserverSummary {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(payload)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(ObserverSummary.self, from: data)
  }
}
