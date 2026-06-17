import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the reviews leaf types generated from
/// src/reviews/{avatar,body_update,file_comment,review_thread_resolve}.rs. The
/// *Wire types own the snake_case shape (explicit CodingKeys, plain decoder); the
/// hand models keep their acronym casing (avatarURL, SHA256). This pins the
/// model->wire encode keys, the wire->model decode, the DateTime->String field,
/// and the open/closed enum mappings.
@Suite("Reviews leaves wire types decoding")
struct ReviewsLeavesWireTypesDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a body update response wire and maps it to the rich model")
  func decodesBodyUpdateResponse() throws {
    let json = #"""
    {"pull_request_id":"pr-1","outcome":"body_drifted","current_body":"new","current_body_sha256":"abc","pr_updated_at":"2026-06-15T18:30:45Z","fetched_at":"2026-06-15T18:31:00Z"}
    """#
    let wire = try decoder.decode(ReviewsBodyUpdateResponseWire.self, from: Data(json.utf8))
    let model = ReviewsBodyUpdateResponse(wire: wire)

    #expect(model.pullRequestID == "pr-1")
    #expect(model.outcome == .bodyDrifted)
    #expect(model.currentBodySHA256 == "abc")
    #expect(model.prUpdatedAt == "2026-06-15T18:30:45Z")
  }

  @Test("maps a file comment request to the wire type with snake_case keys")
  func mapsFileCommentRequestToWire() throws {
    let request = ReviewsFileCommentRequest(
      pullRequestId: "pr-2",
      kind: .newThread,
      body: "looks good",
      line: 42
    )
    let wire = ReviewsFileCommentRequestWire(request)
    #expect(wire.kind == .newThread)

    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any]
    )
    #expect(object["pull_request_id"] as? String == "pr-2")
    #expect(object["kind"] as? String == "new_thread")
    #expect(object["line"] as? Int == 42)
    #expect(object["repository"] == nil)
  }

  @Test("maps an avatar response wire to the rich model with acronym casing")
  func mapsAvatarResponse() throws {
    let wire = ReviewsAvatarResponseWire(
      avatarUrl: "https://example.com/a.png",
      mimeType: "image/png",
      contentBase64: "AAAA",
      fetchedAt: "2026-06-15T00:00:00Z"
    )
    let model = ReviewsAvatarResponse(wire: wire)

    #expect(model.avatarURL == "https://example.com/a.png")
    #expect(model.mimeType == "image/png")
  }
}
