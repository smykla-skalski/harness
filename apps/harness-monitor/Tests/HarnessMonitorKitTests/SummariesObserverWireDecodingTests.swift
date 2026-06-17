import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for the observer summary cluster, generated from
/// src/daemon/protocol/summaries.rs (ObserverSummary/ObserverOpenIssue/
/// ObserverActiveWorker/ObserverAgentSessionSummary). ObserverOpenIssue is the
/// first wire consumer of the observe classification enums - it decodes code/
/// severity/category/fixSafety as the typed IssueCode/IssueSeverity/IssueCategory/
/// FixSafety, proving the daemon's snake_case payload lands in the typed form. The
/// rich hand ObserverSummary still decodes those as String today, so this pins the
/// generated wire shape ahead of the SessionDetail reroute that adopts it.
@Suite("Observer summary wire cluster")
struct SummariesObserverWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes the cluster with typed classification enums in context")
  func decodesTypedClassificationEnums() throws {
    let summary = try decoder.decode(
      ObserverSummaryWire.self, from: Data(summariesObserverPayloadFixture.utf8)
    )

    #expect(summary.observeId == "obs-7")
    #expect(summary.openIssueCount == 2)
    #expect(summary.resolvedIssueCount == 5)
    #expect(summary.mutedCodeCount == 1)
    #expect(summary.activeWorkerCount == 1)

    let issue = try #require(summary.openIssues.first)
    #expect(issue.code == .hookDeniedToolCall)
    #expect(issue.severity == .critical)
    #expect(issue.category == .hookFailure)
    #expect(issue.fixSafety == .triageRequired)
    #expect(issue.firstSeenLine == 12)
    #expect(issue.occurrenceCount == 3)
    #expect(issue.lastSeenLine == 44)
    #expect(issue.evidenceExcerpt == "guard-bash denied")
  }

  @Test("decodes unrecognized classification values to the open-enum fallback")
  func decodesUnknownClassificationFallback() throws {
    let summary = try decoder.decode(
      ObserverSummaryWire.self, from: Data(summariesObserverPayloadFixture.utf8)
    )
    let future = try #require(summary.openIssues.last)

    #expect(future.code == .unknown("future_unmapped_code"))
    #expect(future.severity == .unknown("catastrophic"))
    #expect(future.category == .unknown("from_the_future"))
    #expect(future.fixSafety == .autoFixSafe)
    #expect(future.evidenceExcerpt == nil)
  }

  @Test("decodes muted codes and the nested worker/session collections")
  func decodesNestedCollections() throws {
    let summary = try decoder.decode(
      ObserverSummaryWire.self, from: Data(summariesObserverPayloadFixture.utf8)
    )

    #expect(summary.mutedCodes == [.nonZeroExitCode])

    let worker = try #require(summary.activeWorkers.first)
    #expect(worker.issueId == "iss-1")
    #expect(worker.targetFile == "src/main.rs")
    #expect(worker.agentId == "agent-9")

    let session = try #require(summary.agentSessions.first)
    #expect(session.agentId == "agent-9")
    #expect(session.cursor == 100)
    #expect(session.logPath == "observe/agent-9.log")
  }
}

private let summariesObserverPayloadFixture = """
  {
    "observe_id": "obs-7",
    "last_scan_time": "2026-06-17T10:00:00Z",
    "open_issue_count": 2,
    "resolved_issue_count": 5,
    "muted_code_count": 1,
    "active_worker_count": 1,
    "open_issues": [
      {
        "issue_id": "iss-1",
        "code": "hook_denied_tool_call",
        "severity": "critical",
        "category": "hook_failure",
        "summary": "Hook blocked a tool call",
        "fingerprint": "fp-abc",
        "first_seen_line": 12,
        "occurrence_count": 3,
        "last_seen_line": 44,
        "fix_safety": "triage_required",
        "evidence_excerpt": "guard-bash denied"
      },
      {
        "issue_id": "iss-2",
        "code": "future_unmapped_code",
        "severity": "catastrophic",
        "category": "from_the_future",
        "summary": "Unrecognized future issue",
        "fingerprint": "fp-def",
        "first_seen_line": 1,
        "occurrence_count": 1,
        "last_seen_line": 1,
        "fix_safety": "auto_fix_safe"
      }
    ],
    "muted_codes": ["non_zero_exit_code"],
    "active_workers": [
      {
        "issue_id": "iss-1",
        "target_file": "src/main.rs",
        "started_at": "2026-06-17T09:30:00Z",
        "agent_id": "agent-9",
        "runtime": "claude"
      }
    ],
    "agent_sessions": [
      {
        "agent_id": "agent-9",
        "runtime": "claude",
        "log_path": "observe/agent-9.log",
        "cursor": 100,
        "last_activity": "2026-06-17T09:59:00Z"
      }
    ]
  }
  """
