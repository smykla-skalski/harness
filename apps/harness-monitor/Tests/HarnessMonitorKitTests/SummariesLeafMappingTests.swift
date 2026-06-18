import Foundation
import Testing

@testable import HarnessMonitorKit

/// Map-contract regression for the dashboard leaf types whose generated wires already existed but
/// gained wire -> model maps for their decode-site reroute: ProjectSummary (nests WorktreeSummary)
/// and TimelineWindowResponse (nests TimelineCursor + TimelineEntry). Both narrow UInt counts to Int.
@Suite("Summaries leaf mapping")
struct SummariesLeafMappingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("project summary maps worktrees and narrows session counts")
  func projectSummaryMapping() throws {
    let payload = #"""
      {
        "project_id": "p1", "name": "Proj", "project_dir": "/p", "context_root": "/r",
        "active_session_count": 2, "total_session_count": 5,
        "worktrees": [
          {"checkout_id": "w1", "name": "main", "checkout_root": "/w", "context_root": "/r",
           "active_session_count": 1, "total_session_count": 3}
        ]
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(ProjectSummaryWire.self, from: data)
    let summary = ProjectSummary(wire: wire)

    #expect(summary.projectId == "p1")
    #expect(summary.activeSessionCount == 2)
    #expect(summary.totalSessionCount == 5)
    #expect(summary.worktrees.count == 1)
    #expect(summary.worktrees.first?.checkoutId == "w1")
    #expect(summary.worktrees.first?.totalSessionCount == 3)
  }

  @Test("timeline window response maps cursors and entries, narrowing counts")
  func timelineWindowMapping() throws {
    let payload = #"""
      {
        "revision": 7, "total_count": 12, "window_start": 0, "window_end": 10,
        "has_older": false, "has_newer": true,
        "oldest_cursor": {"recorded_at": "2026-06-18T09:00:00Z", "entry_id": "e1"},
        "newest_cursor": {"recorded_at": "2026-06-18T10:00:00Z", "entry_id": "e10"},
        "entries": [
          {"entry_id": "e1", "recorded_at": "2026-06-18T09:00:00Z", "kind": "task",
           "session_id": "s1", "summary": "started", "payload": {"x": 1}}
        ],
        "unchanged": false
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(TimelineWindowResponseWire.self, from: data)
    let response = TimelineWindowResponse(wire: wire)

    #expect(response.revision == 7)
    #expect(response.totalCount == 12)
    #expect(response.windowEnd == 10)
    #expect(response.hasNewer == true)
    #expect(response.oldestCursor?.entryId == "e1")
    #expect(response.newestCursor?.entryId == "e10")
    #expect(response.entries?.count == 1)
    #expect(response.entries?.first?.kind == "task")
  }
}
