import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the task_board sync summary (syncTaskBoard). Generated from
/// summary.rs + external/sync.rs; the external provider/action enums ride bare and the
/// changed_fields/unsupported_fields lists (no Swift mirror) are dropped. Also pins the
/// conflict action the hand enum gained so a populated operations list decodes.
@Suite("Task board sync summary wire decoding")
struct TaskBoardSyncSummaryWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("sync summary maps providers and operations, tolerating the dropped field lists")
  func syncSummaryMapping() throws {
    let payload = #"""
      {
        "total": 5,
        "providers": [
          {"provider": "github", "configured": true, "linked": 3, "pushable": 1,
           "blocked": 0, "token_env": ["GH_TOKEN"]}
        ],
        "operations": [
          {"provider": "github", "action": "conflict", "board_item_id": "b1",
           "external_id": "e1", "url": "https://example.com/1", "dry_run": true, "applied": false,
           "changed_fields": ["title"], "unsupported_fields": ["labels"]}
        ]
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(TaskBoardSyncSummaryWire.self, from: data)
    let summary = TaskBoardSyncSummary(wire: wire)

    #expect(summary.total == 5)
    #expect(summary.providers.count == 1)
    #expect(summary.providers.first?.provider == .gitHub)
    #expect(summary.providers.first?.linked == 3)
    #expect(summary.providers.first?.tokenEnv == ["GH_TOKEN"])
    #expect(summary.operations.count == 1)
    #expect(summary.operations.first?.provider == .gitHub)
    #expect(summary.operations.first?.action == .conflict)
    #expect(summary.operations.first?.boardItemId == "b1")
    #expect(summary.operations.first?.dryRun == true)
  }
}
