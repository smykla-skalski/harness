import Foundation
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

  @Test("Non-renderable ACP payloads reject action execution")
  func invalidPayloadRejectsActionExecution() {
    let payload = AcpPermissionDecisionPayload.make(
      batch: AcpPermissionBatch(
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
      ),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )

    do {
      _ = try payload.actionDecision(
        for: AcpPermissionDecisionActionID.approve,
        resolutionState: nil
      )
      Issue.record("Expected non-renderable ACP payload to reject action execution")
    } catch let error as AcpPermissionDecisionActionError {
      #expect(error == .notRenderable)
    } catch {
      Issue.record("Expected AcpPermissionDecisionActionError, got \(error)")
    }
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
    #expect(payload?.summary == AcpPermissionDecisionPayload.unavailableSummary)
    #expect(payload?.rawBatch.batchId == "batch-broken")
  }

  @Test("Persisted ACP payloads are revalidated on decode")
  func persistedPayloadsAreRevalidatedOnDecode() {
    let invalidBatch = AcpPermissionBatch(
      batchId: "batch-stale",
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
    let stalePayload = AcpPermissionDecisionPayload(
      decisionID: "acp-permission:batch-stale",
      summary: "Stale summary",
      agent: .init(
        agentID: "worker-codex",
        agentName: "Worker Codex",
        managedAgentID: "acp-1"
      ),
      rawBatch: invalidBatch,
      renderableBatch: .init(
        batch: invalidBatch,
        requests: [
          .init(
            id: "request-stale",
            title: "Stale action",
            detail: "echo stale",
            breadcrumb: "terminal.create"
          )
        ]
      ),
      renderError: nil
    )
    let decision = Decision(
      id: "acp-permission:batch-stale",
      severity: .warn,
      ruleID: AcpPermissionDecisionPayload.ruleID,
      sessionID: "sess-1",
      agentID: "worker-codex",
      taskID: nil,
      summary: "Persisted row summary",
      contextJSON: stalePayload.encodeJSONString(),
      suggestedActionsJSON: stalePayload.encodedSuggestedActionsJSON()
    )

    let payload = AcpPermissionDecisionPayload.decode(from: decision)

    #expect(payload?.decisionID == decision.id)
    #expect(payload?.renderableBatch == nil)
    #expect(payload?.renderError?.message == "One ACP permission item is missing a request id.")
    #expect(payload?.summary == AcpPermissionDecisionPayload.unavailableSummary)
    #expect(payload?.suggestedActions().isEmpty == true)
  }

  @Test("Persisted ACP payloads fall back when the embedded batch id drifts")
  func persistedPayloadMismatchedBatchIDFallsBack() {
    let payload = AcpPermissionDecisionPayload.decode(
      from: decision(
        id: "acp-permission:batch-row",
        sessionID: "sess-1",
        payloadBatch: AcpPermissionBatch(
          batchId: "batch-other",
          acpId: "acp-1",
          sessionId: "sess-1",
          requests: [
            AcpPermissionItem(
              requestId: "request-1",
              sessionId: "sess-1",
              toolCall: .object(["kind": .string("fs.write_text_file")]),
              options: []
            )
          ],
          createdAt: "2026-04-28T00:00:01Z"
        )
      )
    )

    #expect(payload?.decisionID == "acp-permission:batch-row")
    #expect(payload?.renderableBatch == nil)
    #expect(
      payload?.renderError?.message
        == "Persisted ACP payload did not match the enclosing decision id."
    )
    #expect(payload?.summary == AcpPermissionDecisionPayload.unavailableSummary)
    #expect(payload?.rawBatch.batchId == "batch-row")
  }

  @Test("Persisted ACP payloads fall back when the embedded session drifts")
  func persistedPayloadMismatchedSessionFallsBack() {
    let payload = AcpPermissionDecisionPayload.decode(
      from: decision(
        id: "acp-permission:batch-row",
        sessionID: "sess-row",
        payloadBatch: AcpPermissionBatch(
          batchId: "batch-row",
          acpId: "acp-1",
          sessionId: "sess-other",
          requests: [
            AcpPermissionItem(
              requestId: "request-1",
              sessionId: "sess-other",
              toolCall: .object(["kind": .string("fs.write_text_file")]),
              options: []
            )
          ],
          createdAt: "2026-04-28T00:00:01Z"
        )
      )
    )

    #expect(payload?.decisionID == "acp-permission:batch-row")
    #expect(payload?.renderableBatch == nil)
    #expect(
      payload?.renderError?.message
        == "Persisted ACP payload did not match the enclosing decision session."
    )
    #expect(payload?.summary == AcpPermissionDecisionPayload.unavailableSummary)
    #expect(payload?.rawBatch.sessionId == "sess-row")
  }

  @Test("ACP deadlines show a live countdown while traffic is fresh")
  func deadlineStatusShowsCountdown() {
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(expiresAt: isoString(now.addingTimeInterval(61))),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )

    let status = payload.deadlineStatus(now: now, lastMessageAt: now)

    #expect(status?.phase == .pending)
    #expect(status?.label == "expires in 1:01")
    #expect(status?.symbolName == "clock")
    #expect(status?.accessibilityValue == "expires in 1 minute 1 second")
  }

  @Test("ACP deadlines switch to expiring soon with a non-colour cue")
  func deadlineStatusShowsExpiringSoonCue() {
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(expiresAt: isoString(now.addingTimeInterval(29))),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )

    let status = payload.deadlineStatus(now: now, lastMessageAt: now)

    #expect(status?.phase == .expiring)
    #expect(status?.label == "expiring soon — 0:29")
    #expect(status?.symbolName == "clock.badge.exclamationmark")
    #expect(status?.accessibilityValue == "expiring soon, 29 seconds remaining")
  }

  @Test("ACP deadlines become expired after the daemon deadline when traffic is fresh")
  func deadlineStatusShowsExpiredState() {
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(expiresAt: isoString(now.addingTimeInterval(-1))),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )

    let status = payload.deadlineStatus(now: now, lastMessageAt: now)

    #expect(status?.phase == .expired)
    #expect(status?.label == "expired")
    #expect(status?.accessibilityValue == "expired")
  }

  @Test("ACP deadlines fall back to expires soon after 30 seconds without daemon traffic")
  func deadlineStatusUsesClockSkewTolerance() {
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(expiresAt: isoString(now.addingTimeInterval(20))),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )

    let staleMessageAt = now.addingTimeInterval(-31)
    let status = payload.deadlineStatus(now: now, lastMessageAt: staleMessageAt)

    #expect(status?.phase == .stale)
    #expect(status?.label == "expires soon")
    #expect(status?.symbolName == "clock.badge.exclamationmark")
    #expect(status?.accessibilityValue == "expires soon")
  }

  private func makeBatch(expiresAt: String? = nil) -> AcpPermissionBatch {
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
      createdAt: "2026-04-28T00:00:01Z",
      expiresAt: expiresAt
    )
  }

  private func isoString(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private func decision(
    id: String,
    sessionID: String,
    payloadBatch: AcpPermissionBatch
  ) -> Decision {
    let payload = AcpPermissionDecisionPayload(
      decisionID: id,
      summary: "Persisted row summary",
      agent: .init(
        agentID: "worker-codex",
        agentName: "Worker Codex",
        managedAgentID: payloadBatch.acpId
      ),
      rawBatch: payloadBatch,
      renderableBatch: .init(
        batch: payloadBatch,
        requests: [
          .init(
            id: payloadBatch.requests.first?.requestId ?? "request-stale",
            title: "Stale action",
            detail: "echo stale",
            breadcrumb: "terminal.create"
          )
        ]
      ),
      renderError: nil
    )
    return Decision(
      id: id,
      severity: .warn,
      ruleID: AcpPermissionDecisionPayload.ruleID,
      sessionID: sessionID,
      agentID: "worker-codex",
      taskID: nil,
      summary: "Persisted row summary",
      contextJSON: payload.encodeJSONString(),
      suggestedActionsJSON: payload.encodedSuggestedActionsJSON()
    )
  }
}
