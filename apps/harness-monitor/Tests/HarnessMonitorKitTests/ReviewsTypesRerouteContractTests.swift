import Foundation
import Testing

@testable import HarnessMonitorKit

/// End-to-end proof that the reviews types.rs leaf endpoints - repository
/// catalog, cache-clear and body - decode through the generated *Wire types and
/// the plain PolicyWireCoding decoder, then map to the hand models. The daemon
/// emits snake_case; the wire types own that shape with explicit CodingKeys, so
/// the cache cleared_entries and the body pull_request_id / pr_updated_at no
/// longer ride .convertFromSnakeCase. Run through the real HTTP client and
/// WebSocket transport against the daemon's byte-for-byte payload.
@Suite("Reviews types leaf decode reroute")
struct ReviewsTypesRerouteContractTests {
  @Test("HTTP client decodes catalog, cache and body through the wire types")
  func httpTypesLeafReroute() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeHTTPClient()

    let catalog = try await client.catalogReviewRepositories(
      request: ReviewsRepositoryCatalogRequest(organization: "example")
    )
    let cache = try await client.clearReviewsCache()
    let body = try await client.fetchReviewBody(
      request: ReviewsBodyRequest(pullRequestID: "PR_body1")
    )

    assertCatalog(catalog)
    assertCache(cache)
    assertBody(body)
  }

  @Test("WebSocket transport decodes catalog, cache and body through the wire types")
  func webSocketTypesLeafReroute() async throws {
    let probe = RPCProbe()
    let transport = try makeWebSocketTransport(probe: probe)

    let catalog = try await transport.catalogReviewRepositories(
      request: ReviewsRepositoryCatalogRequest(organization: "example")
    )
    let cache = try await transport.clearReviewsCache()
    let body = try await transport.fetchReviewBody(
      request: ReviewsBodyRequest(pullRequestID: "PR_body1")
    )

    assertCatalog(catalog)
    assertCache(cache)
    assertBody(body)

    let methods = await probe.calls.map(\.method)
    #expect(
      methods == [
        .reviewsRepositoryCatalog,
        .reviewsClearCache,
        .reviewsBody,
      ]
    )
  }

  private func assertCatalog(_ response: ReviewsRepositoryCatalogResponse) {
    #expect(response.organization == "example")
    #expect(response.repositories == ["example/aff", "example/harness"])
  }

  private func assertCache(_ response: ReviewsCacheClearResponse) {
    #expect(response.clearedEntries == 2)
  }

  private func assertBody(_ response: ReviewsBodyResponse) {
    #expect(response.pullRequestID == "PR_body1")
    #expect(response.body == "## Summary\nThis PR does the thing.")
    #expect(response.prUpdatedAt == "2026-05-22T09:00:00Z")
    #expect(response.fetchedAt == "2026-05-22T10:00:00Z")
    #expect(response.fromCache == false)
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
