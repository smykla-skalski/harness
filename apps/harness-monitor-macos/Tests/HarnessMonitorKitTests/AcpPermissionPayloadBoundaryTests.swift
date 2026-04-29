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
    "oversized-batch",
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

  private func malformedBatch(for caseID: String) -> AcpPermissionBatch {
    switch caseID {
    case "missing-batch-id":
      return makeBatch(batchID: "")
    case "missing-session-id":
      return makeBatch(sessionID: "")
    case "missing-request-id":
      return makeBatch(requestID: "")
    case "oversized-batch":
      return makeBatch(requestCount: AcpPermissionDecisionPayload.maximumRequestCount + 1)
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
    case "oversized-batch":
      return "The ACP batch exceeded the supported 8-request limit."
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

  private func fittingSize(for decision: Decision) -> CGSize {
    let host = NSHostingView(
      rootView: DecisionRow(
        decision: decision,
        isSelected: false,
        fontScale: 1,
        select: {}
      )
    )
    host.frame = CGRect(x: 0, y: 0, width: 360, height: 120)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }
}
