import Foundation
import Testing

@testable import HarnessMonitorKit

/// End-to-end proof that listReviewFiles decodes through the generated
/// ReviewsFilesListResponseWire / ReviewFileWire types and the plain
/// PolicyWireCoding decoder, then maps to the rich hand models
/// (HarnessMonitorReviewsFiles+Wire). The daemon emits snake_case; the wire
/// types own that shape with explicit CodingKeys, so the file-list decode no
/// longer rides the transport's .convertFromSnakeCase. Run through the real
/// HTTP client and WebSocket transport against the daemon's byte-for-byte
/// payload so a dropped field, a wrong enum mapping, or the renamed
/// language_hint fails here.
@Suite("Reviews files list decode reroute")
struct ReviewsFilesRerouteContractTests {
  @Test("HTTP client decodes the file list through the wire types")
  func httpFilesListReroute() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeHTTPClient()

    let response = try await client.listReviewFiles(
      request: ReviewsFilesListRequest(pullRequestID: "PR_kwReview1", forceRefresh: true)
    )

    assertFilesList(response)
  }

  @Test("WebSocket transport decodes the file list through the wire types")
  func webSocketFilesListReroute() async throws {
    let probe = RPCProbe()
    let transport = try makeWebSocketTransport(probe: probe)

    let response = try await transport.listReviewFiles(
      request: ReviewsFilesListRequest(pullRequestID: "PR_kwReview1", forceRefresh: true)
    )

    assertFilesList(response)

    let methods = await probe.calls.map(\.method)
    #expect(methods == [.reviewsFilesList])
  }

  private func assertFilesList(_ response: ReviewsFilesListResponse) {
    #expect(response.pullRequestID == "PR_kwReview1")
    #expect(response.number == 42)
    #expect(response.headRefOid == "abc123")
    #expect(response.headRefName == "feature/x")
    #expect(response.baseRefOid == "def456")
    #expect(response.viewerCanMarkViewed)
    #expect(response.fetchedAt == "2026-05-22T10:00:00Z")
    #expect(response.paginationComplete)

    #expect(response.files.count == 1)
    let file = response.files.first
    #expect(file?.path == "src/main.rs")
    #expect(file?.changeType == .modified)
    #expect(file?.viewerViewedState == .viewed)
    #expect(file?.languageHint == .rust)
    #expect(file?.additions == 10)
    #expect(file?.deletions == 2)
    #expect(file?.isBinary == false)

    #expect(response.rateLimitSnapshot?.remaining == 4900)
    #expect(response.rateLimitSnapshot?.limit == 5000)
    #expect(response.rateLimitSnapshot?.resetAt == "2026-05-22T11:00:00Z")
    #expect(response.rateLimitSnapshot?.cost == 1)
  }

  @Test("HTTP client decodes a file patch through the wire types")
  func httpFilesPatchReroute() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeHTTPClient()

    let response = try await client.patchReviewFiles(
      request: ReviewsFilesPatchRequest(
        pullRequestID: "PR_kwReview1",
        headRefOidExpected: "abc123",
        paths: ["src/main.rs"]
      )
    )

    assertFilesPatch(response)
  }

  @Test("WebSocket transport decodes a file patch through the wire types")
  func webSocketFilesPatchReroute() async throws {
    let probe = RPCProbe()
    let transport = try makeWebSocketTransport(probe: probe)

    let response = try await transport.patchReviewFiles(
      request: ReviewsFilesPatchRequest(
        pullRequestID: "PR_kwReview1",
        headRefOidExpected: "abc123",
        paths: ["src/main.rs"]
      )
    )

    assertFilesPatch(response)

    let methods = await probe.calls.map(\.method)
    #expect(methods == [.reviewsFilesPatch])
  }

  private func assertFilesPatch(_ response: ReviewsFilesPatchResponse) {
    #expect(response.pullRequestID == "PR_kwReview1")
    #expect(response.drifted == false)
    #expect(response.currentHeadRefOid == "abc123")

    #expect(response.patches.count == 1)
    let patch = response.patches.first
    #expect(patch?.path == "src/main.rs")
    #expect(patch?.status == .modified)
    #expect(patch?.servedBy == .localClone)
    #expect(patch?.additions == 1)
    #expect(patch?.deletions == 1)
    #expect(patch?.etag == "abc-etag")
    #expect(patch?.headRefOid == "abc123")

    #expect(response.rateLimitSnapshot?.remaining == 4800)
    #expect(response.rateLimitSnapshot?.cost == 2)
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
