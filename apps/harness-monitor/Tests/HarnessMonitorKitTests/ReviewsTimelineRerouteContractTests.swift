import Foundation
import Testing

@testable import HarnessMonitorKit

/// End-to-end proof that fetchReviewTimeline decodes through the generated
/// ReviewsTimelineResponseWire / ReviewTimelineEntryWire tagged enum and the
/// plain PolicyWireCoding decoder, then maps to the rich hand timeline models
/// (HarnessMonitorReviewsTimeline+Wire). The daemon emits a flattened
/// internally-tagged `kind` enum in snake_case; the wire types own that shape
/// with explicit CodingKeys, so the timeline decode no longer rides
/// .convertFromSnakeCase. Run through the real HTTP client and WebSocket
/// transport against the daemon's byte-for-byte payload so a dropped field, a
/// wrong variant, the actor/avatar_url bridge, or the unknown raw_payload bridge
/// fails here.
@Suite("Reviews timeline decode reroute")
struct ReviewsTimelineRerouteContractTests {
  @Test("HTTP client decodes the timeline through the wire tagged enum")
  func httpTimelineReroute() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeHTTPClient()

    let response = try await client.fetchReviewTimeline(
      request: ReviewsTimelineRequest(pullRequestId: "pr-42")
    )

    assertTimeline(response)
  }

  @Test("WebSocket transport decodes the timeline through the wire tagged enum")
  func webSocketTimelineReroute() async throws {
    let probe = RPCProbe()
    let transport = try makeWebSocketTransport(probe: probe)

    let response = try await transport.fetchReviewTimeline(
      request: ReviewsTimelineRequest(pullRequestId: "pr-42")
    )

    assertTimeline(response)

    let methods = await probe.calls.map(\.method)
    #expect(methods == [.reviewsTimeline])
  }

  private func assertTimeline(_ response: ReviewsTimelineResponse) {
    #expect(response.pullRequestId == "pr-42")
    #expect(response.viewerCanComment)
    #expect(response.pageInfo.hasOlder)
    #expect(response.pageInfo.hasNewer == false)
    #expect(response.pageInfo.startCursor == "start")
    #expect(response.entries.count == 7)

    assertIssueComment(response.entries[safe: 0])
    assertReview(response.entries[safe: 1])
    assertReviewThread(response.entries[safe: 2])
    assertCommit(response.entries[safe: 3])
    assertHeadRefForcePushed(response.entries[safe: 4])
    assertSimpleActorEvent(response.entries[safe: 5])
    assertUnknown(response.entries[safe: 6])
  }

  private func assertIssueComment(_ entry: ReviewTimelineEntry?) {
    guard case .issueComment(let payload)? = entry else {
      Issue.record("expected issueComment entry")
      return
    }
    #expect(payload.id == "IC_001")
    #expect(payload.body == "ship it")
    #expect(payload.bodyText == "ship it")
    #expect(payload.reactionsTotal == 3)
    #expect(payload.viewerCanEdit)
    #expect(payload.actor?.login == "alice")
    #expect(payload.actor?.avatarURL == URL(string: "https://avatars.example/alice.png"))
  }

  private func assertReview(_ entry: ReviewTimelineEntry?) {
    guard case .review(let payload)? = entry else {
      Issue.record("expected review entry")
      return
    }
    #expect(payload.id == "RV_002")
    #expect(payload.state == .changesRequested)
    #expect(payload.actor?.login == "bob")
    #expect(payload.actor?.avatarURL == nil)
    #expect(payload.inlineComments.count == 1)
    #expect(payload.inlineComments.first?.id == "RC_002a")
    #expect(payload.inlineComments.first?.line == 12)
    #expect(payload.inlineComments.first?.diffHunk == "@@ -1 +1 @@")
  }

  private func assertReviewThread(_ entry: ReviewTimelineEntry?) {
    guard case .reviewThread(let payload)? = entry else {
      Issue.record("expected reviewThread entry")
      return
    }
    #expect(payload.id == "RT_003")
    #expect(payload.isResolved)
    #expect(payload.path == "src/lib.rs")
    #expect(payload.line == 7)
    #expect(payload.comments.count == 1)
    #expect(payload.comments.first?.id == "RTC_003a")
    #expect(payload.comments.first?.actor?.login == "carol")
  }

  private func assertCommit(_ entry: ReviewTimelineEntry?) {
    guard case .commit(let payload)? = entry else {
      Issue.record("expected commit entry")
      return
    }
    #expect(payload.id == "CM_004")
    #expect(payload.oid == "deadbeefdeadbeef")
    #expect(payload.abbreviatedOid == "deadbee")
    #expect(payload.messageHeadline == "fix the thing")
    #expect(payload.authorLogin == "alice")
  }

  private func assertHeadRefForcePushed(_ entry: ReviewTimelineEntry?) {
    guard case .headRefForcePushed(let payload)? = entry else {
      Issue.record("expected headRefForcePushed entry")
      return
    }
    #expect(payload.id == "HF_005")
    #expect(payload.beforeOid == "1111111aaaa")
    #expect(payload.afterAbbreviatedOid == "2222222")
    #expect(payload.refName == "feature/x")
  }

  private func assertSimpleActorEvent(_ entry: ReviewTimelineEntry?) {
    guard case .simpleActorEvent(let payload)? = entry else {
      Issue.record("expected simpleActorEvent entry")
      return
    }
    #expect(payload.id == "SE_006")
    #expect(payload.eventKind == .labeled)
    #expect(payload.label == "enhancement")
    #expect(payload.labelColor == "84b6eb")
    #expect(entry?.kind == .labeled)
  }

  private func assertUnknown(_ entry: ReviewTimelineEntry?) {
    guard case .unknown(let payload)? = entry else {
      Issue.record("expected unknown entry")
      return
    }
    #expect(payload.id == "UK_007")
    #expect(payload.typename == "MysteryEvent")
    #expect(
      payload.rawPayload
        == .object(
          [
            "foo": .string("bar"),
            "largeInteger": .unsignedInteger(9_007_199_254_740_993),
          ]
        )
    )
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

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
