import Foundation
import Testing

@testable import HarnessMonitorKit

/// End-to-end proof that queryReviews - the highest-traffic reviews decode -
/// runs through the generated ReviewsQueryResponseWire graph and the plain
/// PolicyWireCoding decoder, then maps to the rich hand models. The daemon emits
/// snake_case (pull_request_id, author_association, viewer_can_update, the
/// flattened flags), and the wire types own that shape with explicit
/// CodingKeys, so the nested ReviewItem / ReviewCheck / PullRequestReview graph
/// no longer rides convertFromSnakeCase. Exercised through the real HTTP client
/// and WebSocket transport against a daemon-accurate payload.
@Suite("Reviews query decode reroute")
struct ReviewsQueryRerouteContractTests {
  @Test("HTTP client decodes the query graph through the wire types")
  func httpQueryReroute() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeHTTPClient()

    let response = try await client.queryReviews(
      request: ReviewsQueryRequest(authors: ["renovate[bot]"])
    )

    try assertQuery(response)
  }

  @Test("WebSocket transport decodes the query graph through the wire types")
  func webSocketQueryReroute() async throws {
    let probe = RPCProbe()
    let transport = try makeWebSocketTransport(probe: probe)

    let response = try await transport.queryReviews(
      request: ReviewsQueryRequest(authors: ["renovate[bot]"])
    )

    try assertQuery(response)

    let methods = await probe.calls.map(\.method)
    #expect(methods == [.reviewsQuery])
  }

  private func assertQuery(_ response: ReviewsQueryResponse) throws {
    #expect(response.fetchedAt == "2026-05-20T12:45:00Z")
    #expect(response.fromCache == false)
    #expect(response.summary.total == 1)
    #expect(response.summary.reviewRequired == 1)
    #expect(response.summary.autoApprovable == 1)
    #expect(response.summary.blocked == 0)
    #expect(response.items.count == 1)

    let item = try #require(response.items.first)
    #expect(item.pullRequestID == "pr-42")
    #expect(item.repositoryID == "repo-1")
    #expect(item.repository == "example/harness")
    #expect(item.number == 42)
    #expect(item.authorLogin == "renovate[bot]")
    #expect(item.authorAvatarURL == nil)
    #expect(item.authorAssociation == .none)
    #expect(item.state == .open)
    #expect(item.reviewStatus == .reviewRequired)
    #expect(item.checkStatus == .success)
    #expect(item.viewerCanUpdate == true)
    #expect(item.viewerIsRequestedReviewer == false)
    #expect(item.viewerCanMergeAsAdmin == false)
    #expect(item.headSha == "abc123")
    #expect(item.labels == ["dependencies"])
    #expect(item.additions == 12)
    #expect(item.deletions == 4)
    #expect(item.requiredFailedCheckNames.isEmpty)

    #expect(item.checks.count == 2)
    let firstCheck = try #require(item.checks.first)
    #expect(firstCheck.name == "ci")
    #expect(firstCheck.checkSuiteID == "suite-1")
    #expect(firstCheck.detailsURL != nil)
    let lastCheck = try #require(item.checks.last)
    #expect(lastCheck.name == "legacy/ci")
    #expect(lastCheck.checkSuiteID == nil)

    #expect(item.reviews.count == 1)
    let review = try #require(item.reviews.first)
    #expect(review.author == "review-bot")
    #expect(review.authorAvatarURL == nil)
  }

  private func makeHTTPClient() throws -> HarnessMonitorAPIClient {
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

  private func makeWebSocketTransport(probe: RPCProbe) throws -> WebSocketTransport {
    WebSocketTransport(
      connection: HarnessMonitorConnection(
        endpoint: try #require(URL(string: "http://127.0.0.1:1")),
        token: "token"
      ),
      session: URLSession(configuration: .ephemeral),
      rpcSender: { method, params, _ in
        await probe.record(method: method, params: params)
        return try taskBoardRPCResponse(for: method)
      }
    )
  }
}
