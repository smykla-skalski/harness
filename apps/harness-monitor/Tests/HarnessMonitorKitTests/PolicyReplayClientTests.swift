import Foundation
import HarnessMonitorPolicyModels
import Testing

@testable import HarnessMonitorKit

@Suite("Policy replay client", .serialized)
struct PolicyReplayClientTests {
  @Test("HTTP client posts the replay route and decodes the nested result")
  func httpClientReplaysOverRecordedFeed() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeClient()

    let result = try await client.replayPolicyPipeline(
      request: PolicyPipelineReplayRequest(limit: 25)
    )

    let records = TaskBoardURLProtocol.records
    #expect(records.count == 1)
    #expect(records[0].method == "POST")
    #expect(records[0].path == "/v1/policy-pipeline/replay")
    #expect(records[0].body?["limit"] as? Int == 25)

    #expect(result.sampleSize == 2)
    #expect(result.changedCount == 1)
    #expect(result.decisions.count == 1)
    let row = try #require(result.decisions.first)
    #expect(row.id == "policy-decision-1")
    #expect(row.action == .mergePr)
    #expect(row.changed)
    #expect(!row.insufficientEvidence)
    #expect(row.visitedNodeIds == ["node-merge"])
    #expect(
      row.historicalDecision
        == .allow(reasonCode: .autoMergeAllowed, policyVersion: "task-board-policy-v1")
    )
    #expect(
      row.draftDecision
        == .deny(reasonCode: .checksNotGreen, policyVersion: "task-board-policy-v1")
    )
  }

  private func makeClient() throws -> HarnessMonitorAPIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TaskBoardURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: try #require(URL(string: "http://127.0.0.1:9999")),
        token: "token"
      ),
      session: session
    )
  }
}
