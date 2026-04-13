import Foundation
import Testing

@testable import HarnessMonitorKit

private struct ObserverSummaryPayload: Encodable {
  let observeId: String
  let lastScanTime: String
  let openIssueCount: Int
  let resolvedIssueCount: Int
  let mutedCodeCount: Int
  let activeWorkerCount: Int
  let openIssues: [ObserverIssuePayload]?
  let mutedCodes: [String]?
  let activeWorkers: [ObserverWorkerPayload]?
  let cycleHistory: [ObserverCyclePayload]?
  let agentSessions: [ObserverAgentSessionPayload]?
}

private struct ObserverIssuePayload: Encodable {
  let issueId: String
  let code: String
  let summary: String
  let severity: String
  let category: String
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

private struct ObserverCyclePayload: Encodable {
  let timestamp: String
  let fromLine: Int
  let toLine: Int
  let newIssues: Int
  let resolved: Int
}

private struct ObserverAgentSessionPayload: Encodable {
  let agentId: String
  let runtime: String
  let logPath: String?
  let cursor: Int
  let lastActivity: String?
}

@Suite("Observer summary")
struct ObserverSummaryTests {
  @Test("Observer summary decodes without rich detail")
  func observerSummaryDecodesWithoutRichDetail() throws {
    let payload = ObserverSummaryPayload(
      observeId: "observe-sess-1",
      lastScanTime: "2026-03-28T14:17:45Z",
      openIssueCount: 3,
      resolvedIssueCount: 1,
      mutedCodeCount: 1,
      activeWorkerCount: 2,
      openIssues: nil,
      mutedCodes: nil,
      activeWorkers: nil,
      cycleHistory: nil,
      agentSessions: nil
    )

    let summary = try decodeObserverSummary(from: payload)

    #expect(summary.observeId == "observe-sess-1")
    #expect(summary.openIssues == nil)
    #expect(summary.mutedCodes == nil)
    #expect(summary.activeWorkers == nil)
    #expect(summary.cycleHistory == nil)
    #expect(summary.agentSessions == nil)
  }

  @Test("Observer summary decodes rich detail")
  func observerSummaryDecodesRichDetail() throws {
    let payload = ObserverSummaryPayload(
      observeId: "observe-sess-1",
      lastScanTime: "2026-03-28T14:17:45Z",
      openIssueCount: 3,
      resolvedIssueCount: 2,
      mutedCodeCount: 1,
      activeWorkerCount: 2,
      openIssues: [
        ObserverIssuePayload(
          issueId: "issue-1",
          code: "agent_stalled_progress",
          summary: "worker stalled",
          severity: "critical",
          category: "agent_coordination",
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
      ],
      cycleHistory: [
        ObserverCyclePayload(
          timestamp: "2026-03-28T14:17:45Z",
          fromLine: 0,
          toLine: 42,
          newIssues: 1,
          resolved: 1
        )
      ],
      agentSessions: [
        ObserverAgentSessionPayload(
          agentId: "worker-codex",
          runtime: "codex",
          logPath: "/tmp/raw.jsonl",
          cursor: 42,
          lastActivity: "2026-03-28T14:17:40Z"
        )
      ]
    )

    let summary = try decodeObserverSummary(from: payload)
    let openIssue = try #require(summary.openIssues?.first)
    let activeWorker = try #require(summary.activeWorkers?.first)
    let cycle = try #require(summary.cycleHistory?.first)
    let agentSession = try #require(summary.agentSessions?.first)

    #expect(summary.openIssues?.count == 1)
    #expect(summary.resolvedIssueCount == 2)
    #expect(openIssue.code == "agent_stalled_progress")
    #expect(openIssue.category == "agent_coordination")
    #expect(summary.mutedCodes == ["agent_repeated_error"])
    #expect(activeWorker.agentId == "worker-codex")
    #expect(cycle.resolved == 1)
    #expect(agentSession.runtime == "codex")
    #expect(openIssue.evidenceExcerpt == "No checkpoint for 12 minutes.")
  }

  @Test("Preview observer includes rich observe detail")
  func previewObserverIncludesRichObserveDetail() {
    #expect(PreviewFixtures.observer.openIssues?.count == 3)
    #expect(PreviewFixtures.observer.resolvedIssueCount == 4)
    #expect(PreviewFixtures.observer.mutedCodes == ["agent_repeated_error"])
    #expect(PreviewFixtures.observer.activeWorkers?.count == 2)
    #expect(PreviewFixtures.observer.cycleHistory?.count == 2)
    #expect(PreviewFixtures.observer.agentSessions?.count == 2)
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
