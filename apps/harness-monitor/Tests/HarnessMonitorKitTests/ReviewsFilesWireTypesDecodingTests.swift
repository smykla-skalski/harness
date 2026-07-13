import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the reviews files-core types generated from
/// src/reviews/files/{mod,blob,viewed,preview,service,local_clone}.rs. These
/// *Wire types own the snake_case shape (explicit CodingKeys, plain decoder) and
/// prove the daemon payload decodes: the file enums, the nested rate-limit
/// snapshot, the mime enum, the language_hint field whose Rust type
/// (HarnessCodeLanguage) is renamed to the Swift hand enum
/// HarnessReviewFileLanguage by the generator's rename map, the preview
/// request/response (line_limit defaulting from files/preview.rs), and the two
/// cross-wire facade types (FilesLargeDiffStrategy, LocalCloneListEntry) whose
/// daemon-internal siblings are skipped. Mapping these wire types to the rich
/// hand models is a follow-up.
@Suite("Reviews files wire types decoding")
struct ReviewsFilesWireTypesDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a file wire with its enums and the renamed language hint")
  func decodesReviewFile() throws {
    let json = #"""
      {"path":"src/main.rs","change_type":"modified","additions":10,"deletions":2,
      "viewer_viewed_state":"viewed","is_binary":false,"language_hint":"rust"}
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
    #expect(
      try decoder.decode(ReviewFileChangeTypeWire.self, from: Data("\"renamed\"".utf8)) == .renamed)
    #expect(
      try decoder.decode(ReviewFileViewedStateWire.self, from: Data("\"dismissed\"".utf8))
        == .dismissed)
    #expect(
      try decoder.decode(ReviewFileServedByWire.self, from: Data("\"github_rest_fallback\"".utf8))
        == .githubRestFallback
    )
    #expect(try decoder.decode(ReviewImageMimeWire.self, from: Data("\"png\"".utf8)) == .png)
    #expect(
      try decoder.decode(ReviewFileViewedOutcomeWire.self, from: Data("\"drifted\"".utf8))
        == .drifted)
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

  @Test("decodes a preview request, defaulting the omitted line limit to 1000")
  func decodesPreviewRequest() throws {
    // line_limit is omitted, so it resolves the preview_line_limit default (1000)
    // collected from files/preview.rs; large_diff_strategy is absent -> nil.
    let json = #"""
      {"pull_request_id":"pr-9","head_ref_oid_expected":"abc","paths":["src/lib.rs"]}
      """#
    let request = try decoder.decode(ReviewsFilesPreviewRequestWire.self, from: Data(json.utf8))

    #expect(request.pullRequestId == "pr-9")
    #expect(request.paths == ["src/lib.rs"])
    #expect(request.lineLimit == 1000)
    #expect(request.largeDiffStrategy == nil)
  }

  @Test("decodes a preview response with one bounded preview row")
  func decodesPreviewResponse() throws {
    let json = #"""
      {"pull_request_id":"pr-9","previews":[{"path":"src/lib.rs","patch":"@@ -1 +1 @@\n",
      "status":"modified","additions":1,"deletions":0,"served_by":"local_clone",
      "line_count":1,"line_limit":1000,"has_more":false}],"drifted":false,
      "current_head_ref_oid":"abc","fetched_at":"2026-06-15T00:00:00Z"}
      """#
    let response = try decoder.decode(ReviewsFilesPreviewResponseWire.self, from: Data(json.utf8))

    #expect(response.previews.count == 1)
    #expect(response.previews.first?.servedBy == .localClone)
    #expect(response.drifted == false)
    #expect(response.rateLimitSnapshot == nil)
  }

  @Test("decodes the large-diff strategy and a local clone list entry")
  func decodesLargeDiffStrategyAndClonesEntry() throws {
    // The public wire name treats GitHub as one word.
    #expect(
      try decoder.decode(FilesLargeDiffStrategyWire.self, from: Data("\"force_github_rest\"".utf8))
        == .forceGitHubRest
    )
    #expect(
      try decoder.decode(FilesLargeDiffStrategyWire.self, from: Data("\"force_git_hub_rest\"".utf8))
        == .forceGitHubRest
    )

    let json = #"""
      {"repo_full_name":"o/r","repo_key_segment":"abcd1234","size_bytes":4096,
      "created_at":"2026-06-15T00:00:00Z","last_used_at":"2026-06-15T01:00:00Z",
      "last_fetched_at":"2026-06-15T02:00:00Z"}
      """#
    let entry = try decoder.decode(LocalCloneListEntryWire.self, from: Data(json.utf8))

    #expect(entry.repoFullName == "o/r")
    #expect(entry.sizeBytes == 4096)
    #expect(entry.lastFetchedAt == "2026-06-15T02:00:00Z")
  }

  @Test("defaults an omitted served_by to the default enum variant")
  func decodesPreviewRowDefaultingServedBy() throws {
    // served_by carries #[serde(default)] over the Default-deriving
    // ReviewFileServedBy enum; omitting it falls back to the default variant
    // (githubRest) rather than failing the decode.
    let json = #"""
      {"path":"src/lib.rs","patch":"","status":"added","additions":0,"deletions":0,
      "line_count":0,"line_limit":1000,"has_more":false}
      """#
    let preview = try decoder.decode(ReviewFilePreviewWire.self, from: Data(json.utf8))

    #expect(preview.servedBy == .githubRest)
  }
}
