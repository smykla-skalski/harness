import Testing

@testable import HarnessMonitorKit

struct AcpPermissionDecisionPayloadTests {
  @Test("ACP payloads use deterministic decision ids and render requests")
  func makePayloadUsesDeterministicDecisionID() {
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )

    #expect(payload.decisionID == "acp-permission:batch-1")
    #expect(payload.summary == "Worker Codex requested 2 permissions")
    #expect(payload.renderError == nil)
    #expect(payload.renderableBatch?.requests.map(\.id) == ["request-write", "request-terminal"])
    #expect(payload.selectionSummary == "2 of 2 selected")
    #expect(payload.decisionDraft.id == payload.decisionID)
    #expect(payload.decisionDraft.ruleID == AcpPermissionDecisionPayload.ruleID)
  }

  @Test("Approve Selected produces a partial ACP decision")
  func approveSelectedBuildsApproveSomeDecision() throws {
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )
    var resolutionState = payload.defaultResolutionState
    resolutionState.setSelected(false, for: "request-terminal")

    let result = try payload.actionDecision(
      for: AcpPermissionDecisionActionID.approveSelected,
      resolutionState: resolutionState
    )

    #expect(result.decision == .approveSome(["request-write"]))
    #expect(result.outcome.chosenActionID == AcpPermissionDecisionActionID.approveSelected)
    #expect(payload.selectionSummary(resolutionState: resolutionState) == "1 of 2 selected")
  }

  @Test("Empty ACP approval selection disables Approve Selected and throws")
  func emptySelectionDisablesApproveSelected() {
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )
    var resolutionState = payload.defaultResolutionState
    resolutionState.setSelected(false, for: "request-write")
    resolutionState.setSelected(false, for: "request-terminal")

    #expect(
      payload.isActionDisabled(
        AcpPermissionDecisionActionID.approveSelected,
        resolutionState: resolutionState
      )
    )

    do {
      _ = try payload.actionDecision(
        for: AcpPermissionDecisionActionID.approveSelected,
        resolutionState: resolutionState
      )
      Issue.record("Expected empty selection to reject Approve Selected")
    } catch let error as AcpPermissionDecisionActionError {
      #expect(error == .emptySelection)
    } catch {
      Issue.record("Expected AcpPermissionDecisionActionError, got \(error)")
    }
  }

  @Test("Invalid ACP batches fall back to an explicit render error")
  func invalidBatchUsesRenderableFallback() {
    let invalidBatch = AcpPermissionBatch(
      batchId: "batch-invalid",
      acpId: "acp-1",
      sessionId: "sess-1",
      requests: [
        AcpPermissionItem(
          requestId: "",
          sessionId: "sess-1",
          toolCall: .object(["kind": .string("fs.write_text_file")]),
          options: []
        )
      ],
      createdAt: "2026-04-28T00:00:01Z"
    )

    let payload = AcpPermissionDecisionPayload.make(
      batch: invalidBatch,
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )

    #expect(payload.renderableBatch == nil)
    #expect(payload.renderError?.title == "ACP payload could not be rendered")
    #expect(payload.renderError?.message == "One ACP permission item is missing a request id.")
    #expect(payload.suggestedActions().isEmpty)
  }

  @Test("Malformed persisted ACP context decodes to a non-renderable fallback payload")
  func malformedDecisionContextUsesDecodeFallback() {
    let decision = Decision(
      id: "acp-permission:batch-broken",
      severity: .warn,
      ruleID: AcpPermissionDecisionPayload.ruleID,
      sessionID: "sess-1",
      agentID: "worker-codex",
      taskID: nil,
      summary: "Worker Codex requested 1 permission",
      contextJSON: "{not-json",
      suggestedActionsJSON: "[]"
    )

    let payload = AcpPermissionDecisionPayload.decode(from: decision)

    #expect(payload?.decisionID == decision.id)
    #expect(payload?.renderableBatch == nil)
    #expect(payload?.renderError?.message == "Decision payload could not be decoded.")
    #expect(payload?.rawBatch.batchId == "batch-broken")
  }

  private func makeBatch() -> AcpPermissionBatch {
    AcpPermissionBatch(
      batchId: "batch-1",
      acpId: "acp-1",
      sessionId: "sess-1",
      requests: [
        AcpPermissionItem(
          requestId: "request-write",
          sessionId: "sess-1",
          toolCall: .object([
            "kind": .string("fs.write_text_file"),
            "path": .string("Sources/App.swift"),
          ]),
          options: []
        ),
        AcpPermissionItem(
          requestId: "request-terminal",
          sessionId: "sess-1",
          toolCall: .object([
            "kind": .string("terminal.create"),
            "command": .string("swift test"),
          ]),
          options: []
        ),
      ],
      createdAt: "2026-04-28T00:00:01Z"
    )
  }
}
