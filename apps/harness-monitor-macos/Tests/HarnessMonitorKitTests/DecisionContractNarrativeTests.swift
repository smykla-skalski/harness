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
    func entry(_ lines: String...) -> String {
      lines.joined(separator: " ")
    }

    let expectedEntries = [
      entry(
        "- `AcpPermissionDecision` in `Models/AcpAgentModels.swift`:",
        "approve, deny, and partial-approve semantics for ACP permission batches."
      ),
      entry(
        "- `AcpPermissionDecisionPayload` in",
        "`Supervisor/Decision/AcpPermissionDecision.swift`:",
        "deterministic ACP decision ids, semantic payload validation, and",
        "non-renderable fallback content for ACP Decisions rows."
      ),
      entry(
        "- `AcpPermissionBatch` in `Models/AcpAgentModels.swift`:",
        "one queue element carries `1...N` permission items and uses `batchId`",
        "as the idempotency key."
      ),
      entry(
        "- `BatchResolutionState` in `Models/BatchResolutionState.swift`:",
        "shared per-request toggle and submission state for the Decisions",
        "detail pane and the compatibility ACP modal."
      ),
      entry(
        "- `SupervisorEvent` in `Supervisor/Audit/SupervisorEvent.swift`:",
        "current persisted audit-entry carrier, including the payload slot",
        "for approve-some request arrays and future `uiAnnotation` race notes."
      ),
      entry(
        "- `Decision` in `Supervisor/Decision/Decision.swift`:",
        "queue-level goal, sticky-selection policy, and toggle-lifetime policy."
      ),
      entry(
        "- `HarnessMonitorStore.pendingAcpPermissionBatches` and",
        "`reconcilePresentedAcpPermissionBatch` in",
        "`Stores/HarnessMonitorStore+AcpAgents.swift`:",
        "selected-session queue projection and sticky presentation behavior."
      ),
      entry(
        "- `HarnessMonitorStore.reconcileAcpPermissionDecisions` and",
        "`resolveAcpPermissionDecision` in",
        "`Stores/HarnessMonitorStore+AcpAgents.swift`:",
        "DecisionStore materialization, shared selection-state upkeep, and",
        "daemon resolution bridging for ACP decisions."
      ),
      entry(
        "- `HarnessMonitorStore.applyAcpPermissionBatch`,",
        "`removeAcpPermissionBatch`, `shouldReplacePermissionBatch`, and",
        "`sortedAcpPermissionBatches` in",
        "`Stores/HarnessMonitorStore+AcpAgents.swift`:",
        "batch upsert/removal, replay replacement, and oldest-first queue order."
      ),
      entry(
        "- `HarnessMonitorStore.applyAcpEvents` in",
        "`Stores/HarnessMonitorStore+AcpAgents.swift`:",
        "Swift-side event application boundary after decode."
      ),
      entry(
        "- `DaemonPushEvent.Kind.acpPermissionBatchRemoved` in",
        "`Models/HarnessMonitorDaemonPushEvent.swift`:",
        "resolved, timeout, and daemon-shutdown removals for ACP batches."
      ),
      entry(
        "- `AcpEventBatchPayload` in `Models/HarnessMonitorTimelineModels.swift`:",
        "confirms UI-7 coalescing stays in-process Swift code and does not",
        "require a daemon wire-format change."
      ),
      entry(
        "- `AcpAgentsReconciledPayload` in",
        "`Models/HarnessMonitorDaemonPushEvent.swift`:",
        "confirms reconcile snapshots already exist in-tree and remain",
        "authoritative."
      ),
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

  private func entry(_ parts: String...) -> String {
    parts.joined(separator: " ")
  }
}
