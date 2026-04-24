import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class HarnessMonitorStoreCodexDecisionActionTests: XCTestCase {
  func test_supervisorCodexDecisionResolutionClearsPendingApprovalAndDecision() async throws {
    let client = RecordingHarnessClient()
    let approval = client.codexApprovalFixture()
    let run = client.codexRunFixture(
      mode: .approval,
      status: .waitingApproval,
      pendingApprovals: [approval]
    )
    client.configureCodexRuns([run], for: PreviewFixtures.summary.sessionId)

    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    _ = await store.refreshSelectedCodexRuns()
    store.selectCodexRun(runID: run.runId)

    let decisionID = "codex-approval:\(PreviewFixtures.summary.sessionId):\(approval.approvalId)"
    try await store.insertDecisionForTesting(
      DecisionDraft.fixture(
        id: decisionID,
        severity: .needsUser,
        ruleID: "codex-approval",
        sessionID: PreviewFixtures.summary.sessionId,
        agentID: run.runId,
        summary: approval.title,
        contextJSON: encodedJSONObject([
          "agentID": run.runId,
          "approvalID": approval.approvalId,
          "receivedAt": "2026-04-23T08:05:00Z",
          "snapshotID": "store-codex-approval",
        ]),
        suggestedActionsJSON: encodedActions([
          SuggestedAction(
            id: "accept",
            title: "Accept",
            kind: .custom,
            payloadJSON: encodedJSONObject([
              "mode": "accept",
              "agentID": run.runId,
              "approvalID": approval.approvalId,
              "decision": "accept",
            ])
          )
        ])
      )
    )
    await settleObservation()

    await waitUntil {
      store.selectedCodexRun?.pendingApprovals.count == 1
        && store.supervisorOpenDecisions.contains(where: { $0.id == decisionID })
    }

    let handler = store.supervisorDecisionActionHandler()
    await handler.resolve(
      decisionID: decisionID,
      outcome: DecisionOutcome(chosenActionID: "accept", note: nil)
    )

    await waitUntil {
      store.selectedCodexRun?.pendingApprovals.isEmpty == true
        && store.selectedCodexRun?.status == .running
        && !store.supervisorOpenDecisions.contains(where: { $0.id == decisionID })
    }

    XCTAssertTrue(
      client.recordedCalls().contains(
        .resolveCodexApproval(
          runID: run.runId,
          approvalID: approval.approvalId,
          decision: .accept
        )
      )
    )
  }

  private func encodedActions(_ actions: [SuggestedAction]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(actions)) ?? Data("[]".utf8)
    return String(data: data, encoding: .utf8) ?? "[]"
  }

  private func encodedJSONObject(_ object: Any) -> String {
    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }

  private func settleObservation() async {
    await Task.yield()
    await Task.yield()
  }

  private func waitUntil(
    timeout: Duration = .seconds(3),
    poll: Duration = .milliseconds(50),
    condition: @escaping @MainActor () -> Bool
  ) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if condition() {
        return
      }
      try? await Task.sleep(for: poll)
    }
    XCTAssertTrue(condition())
  }
}
