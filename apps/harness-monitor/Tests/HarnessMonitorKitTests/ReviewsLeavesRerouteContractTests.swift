import Foundation
import Testing

@testable import HarnessMonitorKit

/// End-to-end proof that the reviews leaf endpoints (avatar / body update /
/// file comment / review-thread resolve) decode through the generated
/// `*Wire` types and the plain `PolicyWireCoding` decoder, then map to the
/// rich hand models. The daemon emits snake_case; the wire types own that
/// shape with explicit `CodingKeys`, so the reroute drops the transport's
/// `.convertFromSnakeCase` dependency on these paths. The fixtures are the
/// daemon's byte-for-byte snake_case payloads, run through the real HTTP
/// client and the real WebSocket transport so a mis-decoded field or a
/// dropped mapping fails here.
@Suite("Reviews leaves decode reroute")
struct ReviewsLeavesRerouteContractTests {
  @Test("HTTP client decodes the four leaf responses through the wire types")
  func httpLeafReroute() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeHTTPClient()

    let avatar = try await client.fetchReviewAvatar(
      request: ReviewsAvatarRequest(
        avatarURL: "https://avatars.githubusercontent.com/in/2740?v=4"
      )
    )
    let bodyUpdate = try await client.updateReviewBody(
      request: ReviewsBodyUpdateRequest(
        pullRequestID: "PR_kwReview1",
        expectedPriorBodySHA256: "prior-sha",
        newBody: "Updated description body."
      )
    )
    let comment = try await client.addReviewFileComment(
      request: ReviewsFileCommentRequest(
        pullRequestId: "PR_kwReview1",
        kind: .newThread,
        body: "Nit: rename this."
      )
    )
    let resolve = try await client.setReviewThreadResolved(
      request: ReviewsReviewThreadResolveRequest(
        threadId: "PRRT_thread1",
        resolved: true,
        pullRequestId: "PR_kwReview1"
      )
    )

    assertLeafResponses(avatar: avatar, bodyUpdate: bodyUpdate, comment: comment, resolve: resolve)
  }

  @Test("WebSocket transport decodes the four leaf responses through the wire types")
  func webSocketLeafReroute() async throws {
    let probe = RPCProbe()
    let transport = try makeWebSocketTransport(probe: probe)

    let avatar = try await transport.fetchReviewAvatar(
      request: ReviewsAvatarRequest(
        avatarURL: "https://avatars.githubusercontent.com/in/2740?v=4"
      )
    )
    let bodyUpdate = try await transport.updateReviewBody(
      request: ReviewsBodyUpdateRequest(
        pullRequestID: "PR_kwReview1",
        expectedPriorBodySHA256: "prior-sha",
        newBody: "Updated description body."
      )
    )
    let comment = try await transport.addReviewFileComment(
      request: ReviewsFileCommentRequest(
        pullRequestId: "PR_kwReview1",
        kind: .newThread,
        body: "Nit: rename this."
      )
    )
    let resolve = try await transport.setReviewThreadResolved(
      request: ReviewsReviewThreadResolveRequest(
        threadId: "PRRT_thread1",
        resolved: true,
        pullRequestId: "PR_kwReview1"
      )
    )

    assertLeafResponses(avatar: avatar, bodyUpdate: bodyUpdate, comment: comment, resolve: resolve)

    let methods = await probe.calls.map(\.method)
    #expect(
      methods == [
        .reviewsAvatar,
        .reviewsBodyUpdate,
        .reviewsFilesComment,
        .reviewsReviewThreadsResolve,
      ]
    )
  }

  private func assertLeafResponses(
    avatar: ReviewsAvatarResponse,
    bodyUpdate: ReviewsBodyUpdateResponse,
    comment: ReviewsFileCommentResponse,
    resolve: ReviewsReviewThreadResolveResponse
  ) {
    #expect(avatar.avatarURL == "https://avatars.githubusercontent.com/in/2740?v=4")
    #expect(avatar.mimeType == "image/png")
    #expect(avatar.contentBase64 == "iVBORw0KGgo=")
    #expect(avatar.fetchedAt == "2026-05-22T10:00:00Z")

    #expect(bodyUpdate.pullRequestID == "PR_kwReview1")
    #expect(bodyUpdate.outcome == .updated)
    #expect(bodyUpdate.currentBody == "Updated description body.")
    #expect(
      bodyUpdate.currentBodySHA256
        == "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    )
    #expect(bodyUpdate.prUpdatedAt == "2026-05-22T10:05:00Z")
    #expect(bodyUpdate.fetchedAt == "2026-05-22T10:05:01Z")

    #expect(comment.pullRequestId == "PR_kwReview1")
    #expect(comment.threadId == "PRRT_thread1")
    #expect(comment.commentId == "PRRC_comment1")
    #expect(comment.url == "https://github.com/example/harness/pull/1#discussion_r1")
    #expect(comment.fetchedAt == "2026-05-22T10:06:00Z")

    #expect(resolve.threadId == "PRRT_thread1")
    #expect(resolve.resolved)
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
