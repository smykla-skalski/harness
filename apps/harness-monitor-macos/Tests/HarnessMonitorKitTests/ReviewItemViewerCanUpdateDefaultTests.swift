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

  // MARK: - JSON helpers

  /// Builds a minimal but decodable `ReviewItem` JSON payload. The
  /// `viewerCanUpdate` parameter is omitted from the JSON when nil so we
  /// exercise the decoder's `decodeIfPresent` branch directly.
  private func makeReviewItemJSON(viewerCanUpdate: Bool?) -> Data {
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
    if let viewerCanUpdate {
      parts.append("\"viewerCanUpdate\": \(viewerCanUpdate)")
    }
    let body = parts.joined(separator: ", ")
    return Data("{\(body)}".utf8)
  }

  private func makeQueryResponseJSON(viewerCanUpdate: Bool?) -> Data {
    let itemJSON = String(decoding: makeReviewItemJSON(viewerCanUpdate: viewerCanUpdate), as: UTF8.self)
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
    let itemJSON = String(decoding: makeReviewItemJSON(viewerCanUpdate: viewerCanUpdate), as: UTF8.self)
    let body = """
      {
        "fetchedAt": "2026-05-01T09:00:00Z",
        "items": [\(itemJSON)]
      }
      """
    return Data(body.utf8)
  }
}
