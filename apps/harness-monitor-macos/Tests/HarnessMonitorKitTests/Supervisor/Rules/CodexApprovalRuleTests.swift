import Foundation
import XCTest

@testable import HarnessMonitorKit

final class CodexApprovalRuleTests: XCTestCase {
  // MARK: - Helpers

  private func makeSnapshot(
    sessionID: String = "sess-1",
    pendingApprovals: [CodexApprovalSnapshot]
  ) -> SessionsSnapshot {
    SessionsSnapshot(
      id: "snap-1",
      createdAt: .fixed,
      hash: "hash-1",
      sessions: [
        SessionSnapshot(
          id: sessionID,
          title: "Session",
          agents: [],
          tasks: [],
          timelineDensityLastMinute: 0,
          observerIssues: [],
          pendingCodexApprovals: pendingApprovals
        )
      ],
      connection: ConnectionSnapshot(
        kind: "connected",
        lastMessageAt: nil,
        reconnectAttempt: 0
      )
    )
  }

  private func makeApproval(
    id: String = "appr-1",
    agentID: String = "agent-1",
    title: String = "Command approval",
    detail: String = "Allow running command?"
  ) -> CodexApprovalSnapshot {
    CodexApprovalSnapshot(
      id: id,
      agentID: agentID,
      title: title,
      detail: detail,
      receivedAt: .fixed
    )
  }

  private func decodeSuggested(_ json: String) throws -> [SuggestedAction] {
    let data = Data(json.utf8)
    return try JSONDecoder().decode([SuggestedAction].self, from: data)
  }

  private func decodePayloadMode(_ json: String) throws -> String {
    struct Body: Decodable { let mode: String }
    let data = Data(json.utf8)
    return try JSONDecoder().decode(Body.self, from: data).mode
  }

  private func decodeContext(_ json: String) throws -> [String: Any] {
    let data = Data(json.utf8)
    let object = try JSONSerialization.jsonObject(with: data)
    return try XCTUnwrap(object as? [String: Any])
  }

  // MARK: - Trigger

  func test_noPendingApprovals_emitsNoActions() async {
    let rule = CodexApprovalRule()
    let snapshot = makeSnapshot(pendingApprovals: [])

    let actions = await rule.evaluate(snapshot: snapshot, context: .empty)

    XCTAssertTrue(actions.isEmpty)
  }

  func test_singlePendingApproval_emitsOneQueueDecision() async {
    let rule = CodexApprovalRule()
    let approval = makeApproval()
    let snapshot = makeSnapshot(pendingApprovals: [approval])

    let actions = await rule.evaluate(snapshot: snapshot, context: .empty)

    XCTAssertEqual(actions.count, 1)
    guard case .queueDecision(let payload) = actions[0] else {
      XCTFail("Expected queueDecision, got \(actions[0])")
      return
    }
    XCTAssertEqual(payload.ruleID, "codex-approval")
    XCTAssertEqual(payload.agentID, "agent-1")
    XCTAssertEqual(payload.sessionID, "sess-1")
    XCTAssertEqual(payload.severity, .needsUser)
    XCTAssertTrue(payload.summary.contains("Command approval"))
  }

  func test_multiplePendingApprovals_emitsOneDecisionEach() async {
    let rule = CodexApprovalRule()
    let approvals = [
      makeApproval(id: "appr-1"),
      makeApproval(id: "appr-2"),
      makeApproval(id: "appr-3"),
    ]
    let snapshot = makeSnapshot(pendingApprovals: approvals)

    let actions = await rule.evaluate(snapshot: snapshot, context: .empty)

    XCTAssertEqual(actions.count, 3)
    let ids = actions.compactMap { action -> String? in
      if case .queueDecision(let payload) = action { return payload.id }
      return nil
    }
    XCTAssertEqual(Set(ids).count, 3)
  }

  // MARK: - Suggested actions / payload

  func test_suggestedActions_titlesAndModes() async throws {
    let rule = CodexApprovalRule()
    let snapshot = makeSnapshot(pendingApprovals: [makeApproval()])

    let actions = await rule.evaluate(snapshot: snapshot, context: .empty)
    guard case .queueDecision(let payload) = actions.first else {
      XCTFail("Expected queueDecision")
      return
    }
    let suggested = try decodeSuggested(payload.suggestedActionsJSON)

    XCTAssertEqual(
      suggested.map(\.title),
      ["Accept", "Accept for session", "Decline", "Cancel"]
    )

    let modes = try suggested.map { try decodePayloadMode($0.payloadJSON) }
    XCTAssertEqual(modes, ["accept", "acceptForSession", "decline", "cancel"])

    for action in suggested {
      XCTAssertEqual(action.kind, .custom)
    }
  }

  func test_suggestedActionPayload_includesApprovalAndAgent() async throws {
    let rule = CodexApprovalRule()
    let approval = makeApproval(id: "appr-42", agentID: "agent-7")
    let snapshot = makeSnapshot(pendingApprovals: [approval])

    let actions = await rule.evaluate(snapshot: snapshot, context: .empty)
    guard case .queueDecision(let payload) = actions.first else {
      XCTFail("Expected queueDecision")
      return
    }
    let suggested = try decodeSuggested(payload.suggestedActionsJSON)
    let accept = try XCTUnwrap(suggested.first)

    struct Body: Decodable {
      let mode: String
      let agentID: String
      let approvalID: String
    }
    let body = try JSONDecoder().decode(Body.self, from: Data(accept.payloadJSON.utf8))
    XCTAssertEqual(body.mode, "accept")
    XCTAssertEqual(body.agentID, "agent-7")
    XCTAssertEqual(body.approvalID, "appr-42")
  }

  func test_contextPayload_omitsRawApprovalTitleAndDetail() async throws {
    let rule = CodexApprovalRule()
    let approval = makeApproval(
      title: "Run deploy --prod?",
      detail: "Command includes environment credentials and a full shell fragment."
    )
    let snapshot = makeSnapshot(pendingApprovals: [approval])

    let actions = await rule.evaluate(snapshot: snapshot, context: .empty)
    guard case .queueDecision(let payload) = actions.first else {
      XCTFail("Expected queueDecision")
      return
    }
    let context = try decodeContext(payload.contextJSON)

    XCTAssertEqual(context["snapshotID"] as? String, "snap-1")
    XCTAssertEqual(context["approvalID"] as? String, "appr-1")
    XCTAssertEqual(context["agentID"] as? String, "agent-1")
    XCTAssertNil(context["title"])
    XCTAssertNil(context["detail"])
  }

  // MARK: - Idempotency

  func test_decisionID_isStablePerApprovalID() async {
    let rule = CodexApprovalRule()
    let approval = makeApproval(id: "appr-stable")

    let first = await rule.evaluate(
      snapshot: makeSnapshot(pendingApprovals: [approval]),
      context: .empty
    )
    let second = await rule.evaluate(
      snapshot: makeSnapshot(pendingApprovals: [approval]),
      context: .empty
    )

    guard
      case .queueDecision(let firstPayload) = first.first,
      case .queueDecision(let secondPayload) = second.first
    else {
      XCTFail("Expected queueDecision in both evaluations")
      return
    }
    XCTAssertEqual(firstPayload.id, secondPayload.id)
    XCTAssertEqual(firstPayload.id, "codex-approval:sess-1:appr-stable")
  }

  func test_decisionID_includesSessionScope() async {
    let rule = CodexApprovalRule()
    let approval = makeApproval(id: "appr-shared")

    let first = await rule.evaluate(
      snapshot: makeSnapshot(sessionID: "sess-1", pendingApprovals: [approval]),
      context: .empty
    )
    let second = await rule.evaluate(
      snapshot: makeSnapshot(sessionID: "sess-2", pendingApprovals: [approval]),
      context: .empty
    )

    guard
      case .queueDecision(let firstPayload) = first.first,
      case .queueDecision(let secondPayload) = second.first
    else {
      XCTFail("Expected queueDecision in both evaluations")
      return
    }

    XCTAssertNotEqual(firstPayload.id, secondPayload.id)
    XCTAssertEqual(firstPayload.id, "codex-approval:sess-1:appr-shared")
    XCTAssertEqual(secondPayload.id, "codex-approval:sess-2:appr-shared")
  }

  func test_actionKey_isStableAcrossEvaluations() async {
    let rule = CodexApprovalRule()
    let approval = makeApproval(id: "appr-key")

    let first = await rule.evaluate(
      snapshot: makeSnapshot(pendingApprovals: [approval]),
      context: .empty
    )
    let second = await rule.evaluate(
      snapshot: makeSnapshot(pendingApprovals: [approval]),
      context: .empty
    )

    XCTAssertEqual(first.first?.actionKey, second.first?.actionKey)
  }

  // MARK: - Metadata

  func test_ruleIdentity() {
    let rule = CodexApprovalRule()
    XCTAssertEqual(rule.id, "codex-approval")
    XCTAssertFalse(rule.name.isEmpty)
    XCTAssertGreaterThanOrEqual(rule.version, 1)
  }

  func test_defaultBehavior_isCautious() {
    let rule = CodexApprovalRule()
    XCTAssertEqual(rule.defaultBehavior(for: "queueDecision"), .cautious)
  }
}
