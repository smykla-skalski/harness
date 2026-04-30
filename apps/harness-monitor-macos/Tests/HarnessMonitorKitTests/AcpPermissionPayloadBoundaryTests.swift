import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("ACP permission payload boundary")
struct AcpPermissionPayloadBoundaryTests {
  nonisolated private static let invalidCaseIDs = [
    "missing-batch-id",
    "missing-session-id",
    "missing-request-id",
    "duplicate-request-id",
    "oversized-batch",
    "invalid-tool-call-type",
    "invalid-tool-call-context-type",
    "invalid-tool-call-context-identifier",
  ]

  @Test(
    "Malformed ACP batches return a renderable fallback without disturbing sidebar grouping",
    arguments: invalidCaseIDs
  )
  func malformedPayloadsReturnRenderableFallback(_ caseID: String) {
    let payload = AcpPermissionDecisionPayload.make(
      batch: malformedBatch(for: caseID),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )

    #expect(payload.renderableBatch == nil)
    #expect(payload.renderError?.message == expectedMessage(for: caseID))
    #expect(payload.summary == "ACP permission request unavailable")
    #expect(payload.decisionDraft.summary == "ACP permission request unavailable")

    let validDecision = Decision(
      id: "baseline-decision",
      severity: .warn,
      ruleID: "baseline-rule",
      sessionID: "sess-1",
      agentID: "agent-1",
      taskID: nil,
      summary: "Baseline decision",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
    let fallbackDecision = decision(from: payload.decisionDraft)
    let groups = DecisionsSidebarViewModel.grouped(
      decisions: [validDecision, fallbackDecision],
      query: "",
      severities: []
    )
    let groupedIDs = Set(groups.flatMap { $0.decisions.map(\.id) })
    #expect(groupedIDs == Set([validDecision.id, fallbackDecision.id]))

    let fallbackRowSize = fittingSize(for: fallbackDecision)
    #expect(fallbackRowSize.width > 0)
    #expect(fallbackRowSize.height > 0)
  }

  @Test("ACP batches at the daemon permission cap stay renderable")
  func daemonCapSizedBatchRemainsRenderable() {
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(requestCount: AcpPermissionDecisionPayload.maximumRequestCount),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )

    #expect(payload.renderError == nil)
    #expect(
      payload.renderableBatch?.requests.count == AcpPermissionDecisionPayload.maximumRequestCount
    )
    #expect(payload.summary == "Worker Codex requested 8 permissions")
  }

  @Test("ACP adapter derives actions from the validated payload")
  func adapterUsesValidatedPayloadActions() {
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(requestCount: AcpPermissionDecisionPayload.maximumRequestCount),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )
    let staleDecision = decision(
      from: payload,
      suggestedActionsJSON: "[]"
    )

    let adapter = DecisionKindContextAdapter(decision: staleDecision, store: nil)

    #expect(
      adapter.suggestedActions(from: []).map(\.id)
        == payload.suggestedActions().map(\.id)
    )
  }

  @Test("ACP adapter suppresses stale actions when the payload is not renderable")
  func adapterSuppressesStaleActionsForInvalidPayload() {
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(toolCall: .string("not-an-object")),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )
    let staleActions = [
      SuggestedAction(
        id: AcpPermissionDecisionActionID.approve,
        title: "Approve",
        kind: .custom,
        payloadJSON: #"{"action":"approve"}"#
      )
    ]
    let staleDecision = decision(
      from: payload,
      suggestedActionsJSON: encode(staleActions)
    )

    let adapter = DecisionKindContextAdapter(decision: staleDecision, store: nil)

    #expect(adapter.suggestedActions(from: staleActions).isEmpty)
  }

  @Test("ACP detail routing keeps invalid payloads on the ACP fallback path")
  func invalidAcpDecisionUsesAcpFallbackRoute() {
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(toolCall: .string("not-an-object")),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )
    let staleDecision = decision(
      from: payload,
      suggestedActionsJSON: "[]"
    )
    let adapter = DecisionKindContextAdapter(decision: staleDecision, store: nil)

    switch adapter.kind {
    case .acpPermission(let resolvedPayload):
      let expectedMessage = "ACP permission items must include a tool-call object."
      #expect(resolvedPayload.renderableBatch == nil)
      #expect(resolvedPayload.renderError?.message == expectedMessage)
    case .generic:
      Issue.record("Invalid ACP payload unexpectedly fell back to the generic detail path")
    }

    let host = hostingView(
      for: DecisionKindContextView(
        adapter: adapter,
        contextSections: [
          .init(title: "Raw context", lines: ["should not render"])
        ]
      )
    )
    #expect(host.fittingSize.width > 0)
    #expect(host.fittingSize.height > 0)
  }

  @Test("Generic detail routing preserves persisted actions and generic context")
  func genericDecisionUsesGenericRoute() {
    let actions = [
      SuggestedAction(
        id: "dismiss",
        title: "Dismiss",
        kind: .dismiss,
        payloadJSON: "{}"
      )
    ]
    let decision = Decision(
      id: "baseline-decision",
      severity: .warn,
      ruleID: "baseline-rule",
      sessionID: "sess-1",
      agentID: "agent-1",
      taskID: nil,
      summary: "Baseline decision",
      contextJSON: "{}",
      suggestedActionsJSON: encode(actions)
    )
    let adapter = DecisionKindContextAdapter(decision: decision, store: nil)

    switch adapter.kind {
    case .generic:
      break
    case .acpPermission:
      Issue.record("Generic decision unexpectedly resolved to the ACP detail path")
    }

    #expect(adapter.suggestedActions(from: actions).map(\.id) == actions.map(\.id))
    #expect(!adapter.isActionDisabled("dismiss"))

    let host = hostingView(
      for: DecisionKindContextView(
        adapter: adapter,
        contextSections: [
          .init(title: "Snapshot", lines: ["agent=agent-1 idle=720s"])
        ]
      )
    )
    #expect(host.fittingSize.width > 0)
    #expect(host.fittingSize.height > 0)
  }

  private func malformedBatch(for caseID: String) -> AcpPermissionBatch {
    switch caseID {
    case "missing-batch-id":
      return makeBatch(batchID: "")
    case "missing-session-id":
      return makeBatch(sessionID: "")
    case "missing-request-id":
      return makeBatch(requestID: "")
    case "duplicate-request-id":
      return makeDuplicateRequestIDBatch()
    case "oversized-batch":
      return makeBatch(requestCount: AcpPermissionDecisionPayload.maximumRequestCount + 1)
    case "invalid-tool-call-type":
      return makeBatch(toolCall: .string("not-an-object"))
    case "invalid-tool-call-context-type":
      return makeBatch(
        toolCall: .object([
          "kind": .string("fs.write_text_file"),
          "path": .string("README.md"),
          "tool_call_context": .string("not-an-object"),
        ])
      )
    case "invalid-tool-call-context-identifier":
      return makeBatch(
        toolCall: .object([
          "kind": .string("terminal.create"),
          "command": .string("swift test"),
          "tool_call_context": .object([
            "phase": .string("preflight")
          ]),
        ])
      )
    default:
      Issue.record("Unhandled ACP payload boundary case: \(caseID)")
      return makeBatch()
    }
  }

  private func expectedMessage(for caseID: String) -> String {
    switch caseID {
    case "missing-batch-id":
      return "The daemon sent an ACP batch without a batch id."
    case "missing-session-id":
      return "The daemon sent an ACP batch without a session id."
    case "missing-request-id":
      return "One ACP permission item is missing a request id."
    case "duplicate-request-id":
      return "ACP permission items must have unique request ids."
    case "oversized-batch":
      return "The ACP batch exceeded the supported 8-request limit."
    case "invalid-tool-call-type":
      return "ACP permission items must include a tool-call object."
    case "invalid-tool-call-context-type":
      return "ACP tool_call_context must be an object when provided."
    case "invalid-tool-call-context-identifier":
      return "ACP tool_call_context is missing a tool-call identifier."
    default:
      return ""
    }
  }

  private func makeBatch(
    batchID: String = "batch-1",
    sessionID: String = "sess-1",
    requestID: String = "request-1",
    requestCount: Int = 1,
    toolCall: JSONValue = .object([
      "kind": .string("fs.write_text_file"),
      "path": .string("README.md"),
    ])
  ) -> AcpPermissionBatch {
    let requests = (0..<requestCount).map { index in
      let requestIDSuffix = requestCount == 1 ? "" : "-\(index)"
      return AcpPermissionItem(
        requestId: "\(requestID)\(requestIDSuffix)",
        sessionId: sessionID,
        toolCall: toolCall,
        options: [.string("allow"), .string("deny")]
      )
    }
    return AcpPermissionBatch(
      batchId: batchID,
      acpId: "acp-1",
      sessionId: sessionID,
      requests: requests,
      createdAt: "2026-04-29T00:00:01Z"
    )
  }

  private func makeDuplicateRequestIDBatch() -> AcpPermissionBatch {
    AcpPermissionBatch(
      batchId: "batch-1",
      acpId: "acp-1",
      sessionId: "sess-1",
      requests: [
        AcpPermissionItem(
          requestId: "request-duplicate",
          sessionId: "sess-1",
          toolCall: .object([
            "kind": .string("fs.write_text_file"),
            "path": .string("README.md"),
          ]),
          options: [.string("allow"), .string("deny")]
        ),
        AcpPermissionItem(
          requestId: "request-duplicate",
          sessionId: "sess-1",
          toolCall: .object([
            "kind": .string("terminal.create"),
            "command": .string("swift test"),
          ]),
          options: [.string("allow"), .string("deny")]
        ),
      ],
      createdAt: "2026-04-29T00:00:01Z"
    )
  }

  private func decision(from draft: DecisionDraft) -> Decision {
    Decision(
      id: draft.id,
      severity: draft.severity,
      ruleID: draft.ruleID,
      sessionID: draft.sessionID,
      agentID: draft.agentID,
      taskID: draft.taskID,
      summary: draft.summary,
      contextJSON: draft.contextJSON,
      suggestedActionsJSON: draft.suggestedActionsJSON
    )
  }

  private func decision(
    from payload: AcpPermissionDecisionPayload,
    suggestedActionsJSON: String
  ) -> Decision {
    Decision(
      id: payload.decisionID,
      severity: .warn,
      ruleID: AcpPermissionDecisionPayload.ruleID,
      sessionID: payload.rawBatch.sessionId,
      agentID: payload.agent.agentID,
      taskID: nil,
      summary: payload.summary,
      contextJSON: payload.encodeJSONString(),
      suggestedActionsJSON: suggestedActionsJSON
    )
  }

  private func encode(_ actions: [SuggestedAction]) -> String {
    guard
      let data = try? JSONEncoder().encode(actions),
      let json = String(data: data, encoding: .utf8)
    else {
      return "[]"
    }
    return json
  }

  private func fittingSize(for decision: Decision) -> CGSize {
    let host = hostingView(
      for: DecisionRow(
        decision: decision,
        isSelected: false,
        fontScale: 1,
        select: {}
      ),
      width: 360,
      height: 120
    )
    return host.fittingSize
  }

  private func hostingView<Content: View>(
    for content: Content,
    width: CGFloat = 520,
    height: CGFloat = 320
  ) -> NSHostingView<Content> {
    let host = NSHostingView(rootView: content)
    host.frame = CGRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    return host
  }
}
