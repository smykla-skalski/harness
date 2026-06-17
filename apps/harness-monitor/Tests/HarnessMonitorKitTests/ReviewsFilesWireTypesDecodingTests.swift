import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the reviews files-core types generated from
/// src/reviews/files/{mod,blob,viewed}.rs. These *Wire types own the snake_case
/// shape (explicit CodingKeys, plain decoder) and prove the daemon payload
/// decodes: the file enums, the nested rate-limit snapshot, the mime enum, and
/// the language_hint field whose Rust type (HarnessCodeLanguage) is renamed to
/// the Swift hand enum HarnessReviewFileLanguage by the generator's rename map.
/// Mapping these wire types to the rich hand models is a follow-up.
@Suite("Reviews files wire types decoding")
struct ReviewsFilesWireTypesDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a file wire with its enums and the renamed language hint")
  func decodesReviewFile() throws {
    let json = #"""
    {"path":"src/main.rs","change_type":"modified","additions":10,"deletions":2,"viewer_viewed_state":"viewed","is_binary":false,"language_hint":"rust"}
    """#
    let file = try decoder.decode(ReviewFileWire.self, from: Data(json.utf8))

    #expect(file.path == "src/main.rs")
    #expect(file.changeType == .modified)
    #expect(file.viewerViewedState == .viewed)
    #expect(file.languageHint == .rust)
    #expect(file.previousPath == nil)
  }

  @Test("decodes the closed file enums from their snake_case wire values")
  func decodesFileEnums() throws {
    #expect(try decoder.decode(ReviewFileChangeTypeWire.self, from: Data("\"renamed\"".utf8)) == .renamed)
    #expect(try decoder.decode(ReviewFileViewedStateWire.self, from: Data("\"dismissed\"".utf8)) == .dismissed)
    #expect(
      try decoder.decode(ReviewFileServedByWire.self, from: Data("\"github_rest_fallback\"".utf8))
        == .githubRestFallback
    )
    #expect(try decoder.decode(ReviewImageMimeWire.self, from: Data("\"png\"".utf8)) == .png)
    #expect(try decoder.decode(ReviewFileViewedOutcomeWire.self, from: Data("\"drifted\"".utf8)) == .drifted)
  }

  @Test("decodes a rate limit snapshot with its snake_case reset key")
  func decodesRateLimitSnapshot() throws {
    let json = #"{"remaining":100,"limit":5000,"reset_at":"2026-06-15T00:00:00Z","cost":1}"#
    let snapshot = try decoder.decode(ReviewsRateLimitSnapshotWire.self, from: Data(json.utf8))

    #expect(snapshot.remaining == 100)
    #expect(snapshot.limit == 5000)
    #expect(snapshot.resetAt == "2026-06-15T00:00:00Z")
    #expect(snapshot.cost == 1)
  }
}
