import Foundation
import Testing

@Suite("Decision contract narrative")
struct DecisionContractNarrativeTests {
  @Test("Narrative index keeps the expected section skeleton")
  func narrativeIndexKeepsExpectedSectionSkeleton() throws {
    let contract = try decisionContract()

    let headings =
      contract
      .split(separator: "\n")
      .filter { $0.hasPrefix("#") }
      .map(String.init)

    #expect(
      headings == [
        "# Decision Contract",
        "## Operating Goal",
        "## Canonical Type Map",
        "## Front-Hall Channel",
        "## UI-6 Authority",
        "## Daemon API Stability Budget",
      ]
    )
  }

  @Test("Narrative index names the concrete contract owners")
  func narrativeIndexNamesConcreteContractOwners() throws {
    let contract = try decisionContract()

    let expectedEntries = [
      [
        "- `AcpPermissionDecision` in `Models/AcpAgentModels.swift`:",
        "approve, deny, and partial-approve semantics for ACP permission batches.",
      ].joined(separator: " "),
      [
        "- `AcpPermissionBatch` in `Models/AcpAgentModels.swift`:",
        "one queue element carries `1...N` permission items and uses `batchId`",
        "as the idempotency key.",
      ].joined(separator: " "),
      [
        "- `SupervisorEvent` in `Supervisor/Audit/SupervisorEvent.swift`:",
        "current persisted audit-entry carrier, including the payload slot",
        "for approve-some request arrays and future `uiAnnotation` race notes.",
      ].joined(separator: " "),
      [
        "- `Decision` in `Supervisor/Decision/Decision.swift`:",
        "queue-level goal, sticky-selection policy, and toggle-lifetime policy.",
      ].joined(separator: " "),
      [
        "- `HarnessMonitorStore.pendingAcpPermissionBatches` and",
        "`reconcilePresentedAcpPermissionBatch` in",
        "`Stores/HarnessMonitorStore+AcpAgents.swift`:",
        "selected-session queue projection and sticky presentation behavior.",
      ].joined(separator: " "),
      [
        "- `HarnessMonitorStore.applyAcpPermissionBatch`,",
        "`removeAcpPermissionBatch`, `shouldReplacePermissionBatch`, and",
        "`sortedAcpPermissionBatches` in",
        "`Stores/HarnessMonitorStore+AcpAgents.swift`:",
        "batch upsert/removal, replay replacement, and oldest-first queue order.",
      ].joined(separator: " "),
      [
        "- `HarnessMonitorStore.applyAcpEvents` in",
        "`Stores/HarnessMonitorStore+AcpAgents.swift`:",
        "Swift-side event application boundary after decode.",
      ].joined(separator: " "),
      [
        "- `DaemonPushEvent.Kind.acpPermissionBatchRemoved` in",
        "`Models/HarnessMonitorDaemonPushEvent.swift`:",
        "timeout and daemon-shutdown removals for ACP batches.",
      ].joined(separator: " "),
      [
        "- `AcpEventBatchPayload` in `Models/HarnessMonitorTimelineModels.swift`:",
        "confirms UI-7 coalescing stays in-process Swift code and does not",
        "require a daemon wire-format change.",
      ].joined(separator: " "),
      [
        "- `AcpAgentsReconciledPayload` in",
        "`Models/HarnessMonitorDaemonPushEvent.swift`:",
        "confirms reconcile snapshots already exist in-tree and remain",
        "authoritative.",
      ].joined(separator: " "),
    ]

    for entry in expectedEntries {
      #expect(contract.contains(entry))
    }
    #expect(contract.contains("single-queue policy enforcement"))
  }

  private func decisionContract(filePath: StaticString = #filePath) throws -> String {
    let repoRoot =
      URL(fileURLWithPath: "\(filePath)")
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contractURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorKit/Models")
      .appendingPathComponent("Decision.contract.md")
    return try String(contentsOf: contractURL, encoding: .utf8)
  }
}
