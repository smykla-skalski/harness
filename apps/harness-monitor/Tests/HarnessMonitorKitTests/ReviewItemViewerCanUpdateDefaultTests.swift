import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("ReviewItem viewerCanUpdate default and daemon shim")
struct ReviewItemViewerCanUpdateDefaultTests {
  @Test("decoder defaults to false when viewerCanUpdate is missing")
  func decoderDefaultsViewerCanUpdateToFalseWhenMissing() throws {
    let json = makeReviewItemJSON(viewerCanUpdate: nil)
    let item = try JSONDecoder().decode(ReviewItem.self, from: json)
    #expect(item.viewerCanUpdate == false)
  }

  @Test("decoder preserves an explicit true value")
  func decoderPreservesExplicitTrue() throws {
    let json = makeReviewItemJSON(viewerCanUpdate: true)
    let item = try JSONDecoder().decode(ReviewItem.self, from: json)
    #expect(item.viewerCanUpdate == true)
  }

  @Test("decoder preserves an explicit false value")
  func decoderPreservesExplicitFalse() throws {
    let json = makeReviewItemJSON(viewerCanUpdate: false)
    let item = try JSONDecoder().decode(ReviewItem.self, from: json)
    #expect(item.viewerCanUpdate == false)
  }

  @Test("decoder preserves authorAvatarUrl when present")
  func decoderPreservesAuthorAvatarURL() throws {
    let json = makeReviewItemJSON(
      viewerCanUpdate: true,
      authorAvatarURL: "https://avatars.githubusercontent.com/in/2740?v=4"
    )
    let item = try JSONDecoder().decode(ReviewItem.self, from: json)
    #expect(
      item.authorAvatarURL?.absoluteString == "https://avatars.githubusercontent.com/in/2740?v=4")
  }

  @Test("decoder defaults authorAvatarURL to nil when missing")
  func decoderDefaultsAuthorAvatarURLToNilWhenMissing() throws {
    let json = makeReviewItemJSON(viewerCanUpdate: true, authorAvatarURL: nil)
    let item = try JSONDecoder().decode(ReviewItem.self, from: json)
    #expect(item.authorAvatarURL == nil)
  }

  @Test("normalizer leaves a current-wire-version response untouched")
  func normalizerSkipsForCurrentDaemon() throws {
    let response = try decode(makeQueryResponseJSON(viewerCanUpdate: false))
    let result = HarnessMonitorReviewsDaemonNormalizer.normalize(
      response: response,
      daemonWireVersion: HarnessMonitorReviewsDaemonNormalizer.viewerCanUpdateMinimumWireVersion
    )
    #expect(result.items.first?.viewerCanUpdate == false)
  }

  @Test("normalizer flips viewerCanUpdate to true for pre-field daemons")
  func normalizerEnablesForOlderDaemon() throws {
    let response = try decode(makeQueryResponseJSON(viewerCanUpdate: nil))
    let preFieldWireVersion =
      HarnessMonitorReviewsDaemonNormalizer.viewerCanUpdateMinimumWireVersion - 1
    let result = HarnessMonitorReviewsDaemonNormalizer.normalize(
      response: response,
      daemonWireVersion: preFieldWireVersion
    )
    #expect(result.items.first?.viewerCanUpdate == true)
  }

  @Test("normalizer treats nil wire version as pre-field daemon")
  func normalizerTreatsMissingWireVersionAsOlder() throws {
    let response = try decode(makeQueryResponseJSON(viewerCanUpdate: nil))
    let result = HarnessMonitorReviewsDaemonNormalizer.normalize(
      response: response,
      daemonWireVersion: nil
    )
    #expect(result.items.first?.viewerCanUpdate == true)
  }

  @Test("normalizer preserves a daemon-emitted true value when shim applies")
  func normalizerLeavesTrueAlone() throws {
    let response = try decode(makeQueryResponseJSON(viewerCanUpdate: true))
    let preFieldWireVersion =
      HarnessMonitorReviewsDaemonNormalizer.viewerCanUpdateMinimumWireVersion - 1
    let result = HarnessMonitorReviewsDaemonNormalizer.normalize(
      response: response,
      daemonWireVersion: preFieldWireVersion
    )
    #expect(result.items.first?.viewerCanUpdate == true)
  }

  @Test("refresh normalizer flips viewerCanUpdate to true for pre-field daemons")
  func refreshNormalizerEnablesForOlderDaemon() throws {
    let refresh = try decodeRefresh(makeRefreshResponseJSON(viewerCanUpdate: nil))
    let preFieldWireVersion =
      HarnessMonitorReviewsDaemonNormalizer.viewerCanUpdateMinimumWireVersion - 1
    let result = HarnessMonitorReviewsDaemonNormalizer.normalize(
      refresh: refresh,
      daemonWireVersion: preFieldWireVersion
    )
    #expect(result.items.first?.viewerCanUpdate == true)
  }

  @Test("refresh normalizer leaves a current-wire-version response untouched")
  func refreshNormalizerSkipsForCurrentDaemon() throws {
    let refresh = try decodeRefresh(makeRefreshResponseJSON(viewerCanUpdate: false))
    let result = HarnessMonitorReviewsDaemonNormalizer.normalize(
      refresh: refresh,
      daemonWireVersion: HarnessMonitorReviewsDaemonNormalizer.viewerCanUpdateMinimumWireVersion
    )
    #expect(result.items.first?.viewerCanUpdate == false)
  }

  @Test("replacing preserves authorAvatarURL")
  func replacingPreservesAuthorAvatarURL() {
    let item = ReviewItem(
      pullRequestID: "PR_1",
      repositoryID: "R_1",
      repository: "acme/api",
      number: 42,
      title: "Fixture",
      url: "https://example.com/PR_1",
      authorLogin: "renovate[bot]",
      authorAvatarURL: URL(string: "https://avatars.githubusercontent.com/in/2740?v=4"),
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .none,
      checkStatus: .none,
      policyBlocked: false,
      isDraft: false,
      headSha: "deadbeef",
      additions: 1,
      deletions: 0,
      createdAt: "2026-05-01T09:00:00Z",
      updatedAt: "2026-05-01T09:00:00Z"
    )
    let replaced = item.replacing(state: .merged)
    #expect(
      replaced.authorAvatarURL?.absoluteString
        == "https://avatars.githubusercontent.com/in/2740?v=4")
  }

  @Test("model source carries author association and reviewer request fields")
  func modelSourceCarriesAuthorAssociationAndReviewerRequestFields() throws {
    let source = try harnessMonitorKitSource(named: "HarnessMonitorReviewsModels.swift")
    #expect(source.contains("public let authorAssociation: ReviewAuthorAssociation"))
    #expect(source.contains("public let viewerIsRequestedReviewer: Bool"))
    #expect(source.contains("case authorAssociation"))
    #expect(source.contains("case viewerIsRequestedReviewer"))
  }

  @Test("daemon normalizer forwards author association and reviewer request fields")
  func daemonNormalizerForwardsAuthorAssociationAndReviewerRequestFields() throws {
    let source = try harnessMonitorKitSource(named: "HarnessMonitorReviewsDaemonNormalizer.swift")
    #expect(source.contains("authorAssociation: item.authorAssociation"))
    #expect(source.contains("viewerIsRequestedReviewer: item.viewerIsRequestedReviewer"))
  }

  // MARK: - JSON helpers

  /// Builds a minimal but decodable `ReviewItem` JSON payload. The
  /// `viewerCanUpdate` parameter is omitted from the JSON when nil so we
  /// exercise the decoder's `decodeIfPresent` branch directly.
  private func makeReviewItemJSON(
    viewerCanUpdate: Bool?,
    authorAvatarURL: String? = nil
  ) -> Data {
    var parts: [String] = [
      "\"pullRequestId\": \"PR_1\"",
      "\"repositoryId\": \"R_1\"",
      "\"repository\": \"acme/api\"",
      "\"number\": 42",
      "\"title\": \"Fixture\"",
      "\"url\": \"https://example.com/PR_1\"",
      "\"authorLogin\": \"octocat\"",
      "\"state\": \"open\"",
      "\"mergeable\": \"mergeable\"",
      "\"reviewStatus\": \"none\"",
      "\"checkStatus\": \"none\"",
      "\"policyBlocked\": false",
      "\"isDraft\": false",
      "\"headSha\": \"deadbeef\"",
      "\"additions\": 1",
      "\"deletions\": 0",
      "\"createdAt\": \"2026-05-01T09:00:00Z\"",
      "\"updatedAt\": \"2026-05-01T09:00:00Z\"",
    ]
    if let authorAvatarURL {
      parts.append("\"authorAvatarUrl\": \"\(authorAvatarURL)\"")
    }
    if let viewerCanUpdate {
      parts.append("\"viewerCanUpdate\": \(viewerCanUpdate)")
    }
    let body = parts.joined(separator: ", ")
    return Data("{\(body)}".utf8)
  }

  private func makeQueryResponseJSON(viewerCanUpdate: Bool?) -> Data {
    let itemJSON =
      String(bytes: makeReviewItemJSON(viewerCanUpdate: viewerCanUpdate), encoding: .utf8) ?? ""
    let body = """
      {
        "fetchedAt": "2026-05-01T09:00:00Z",
        "fromCache": false,
        "summary": {
          "total": 1,
          "reviewRequired": 0,
          "readyToMerge": 0,
          "autoApprovable": 0,
          "waitingOnChecks": 0,
          "blocked": 0
        },
        "items": [\(itemJSON)]
      }
      """
    return Data(body.utf8)
  }

  private func decode(_ data: Data) throws -> ReviewsQueryResponse {
    try JSONDecoder().decode(ReviewsQueryResponse.self, from: data)
  }

  private func decodeRefresh(_ data: Data) throws -> ReviewsRefreshResponse {
    try JSONDecoder().decode(ReviewsRefreshResponse.self, from: data)
  }

  private func makeRefreshResponseJSON(viewerCanUpdate: Bool?) -> Data {
    let itemJSON =
      String(bytes: makeReviewItemJSON(viewerCanUpdate: viewerCanUpdate), encoding: .utf8) ?? ""
    let body = """
      {
        "fetchedAt": "2026-05-01T09:00:00Z",
        "items": [\(itemJSON)]
      }
      """
    return Data(body.utf8)
  }

  private func harnessMonitorKitSource(named fileName: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorKit/Models")
      .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
