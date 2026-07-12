import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto

struct MobileRemoteReviewsSnapshot: Sendable {
  var reviews: [MobileReviewSummary]
  var attention: [MobileAttentionItem]

  static let empty = Self(reviews: [], attention: [])
}

extension MobileRemoteDaemonSyncClient {
  func fetchReviewsSnapshot(now: Date) async throws -> MobileRemoteReviewsSnapshot {
    guard let query = access.reviewsQuery else {
      return .empty
    }
    var request = authenticatedRequest(path: "/v1/reviews/query")
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(query)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MobileRemoteDaemonSyncError.invalidResponse
    }
    try validate(response)
    let wire = try JSONDecoder().decode(MobileRemoteReviewsResponseWire.self, from: data)
    let redactor = MobileMirrorSecretRedactor()
    let reviews = wire.items.map {
      $0.mobileSummary(stationID: stationID, now: now, redactor: redactor)
    }
    let attention = reviews.filter(\.needsYou).map {
      $0.mobileAttention(stationID: stationID, redactor: redactor)
    }
    return MobileRemoteReviewsSnapshot(reviews: reviews, attention: attention)
  }
}

private struct MobileRemoteReviewsResponseWire: Decodable, Sendable {
  var items: [MobileRemoteReviewWire]
}

private struct MobileRemoteReviewWire: Decodable, Sendable {
  var pullRequestID: String
  var repositoryID: String
  var repository: String
  var number: Int
  var title: String
  var url: String
  var authorLogin: String
  var state: String
  var mergeable: String
  var reviewStatus: String
  var checkStatus: String
  var isDraft: Bool?
  var policyBlocked: Bool?
  var viewerCanUpdate: Bool?
  var viewerCanMergeAsAdmin: Bool?
  var headSHA: String
  var labels: [String]?
  var checks: [MobileRemoteReviewCheckWire]?
  var additions: UInt64
  var deletions: UInt64
  var updatedAt: String
  var requiredFailedCheckNames: [String]?

  func mobileSummary(
    stationID: String,
    now: Date,
    redactor: MobileMirrorSecretRedactor
  ) -> MobileReviewSummary {
    MobileReviewSummary(
      id: pullRequestID,
      stationID: stationID,
      repositoryID: repositoryID,
      repository: repository,
      number: number,
      url: redactor.redact(url),
      title: redactor.redact(title),
      author: redactor.redact(authorLogin),
      state: state,
      checksSummary: checkStatus,
      headSha: headSHA,
      mergeable: mergeable,
      reviewStatus: reviewStatus,
      checkStatus: checkStatus,
      policyBlocked: policyBlocked ?? false,
      isDraft: isDraft ?? false,
      labels: (labels ?? []).map(redactor.redact),
      checks: (checks ?? []).prefix(6).enumerated().map { index, check in
        check.mobileSnippet(reviewID: pullRequestID, index: index, redactor: redactor)
      },
      additions: additions,
      deletions: deletions,
      requiredFailedCheckNames: (requiredFailedCheckNames ?? []).map(redactor.redact),
      viewerCanUpdate: viewerCanUpdate ?? true,
      viewerCanMergeAsAdmin: viewerCanMergeAsAdmin ?? false,
      needsYou: needsAttention,
      updatedAt: MobileRemoteSessionDate.parse(updatedAt) ?? now
    )
  }

  private var needsAttention: Bool {
    reviewStatus == "review_required"
      || policyBlocked == true
      || checkStatus == "failure"
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pull_request_id"
    case repositoryID = "repository_id"
    case repository
    case number
    case title
    case url
    case authorLogin = "author_login"
    case state
    case mergeable
    case reviewStatus = "review_status"
    case checkStatus = "check_status"
    case isDraft = "is_draft"
    case policyBlocked = "policy_blocked"
    case viewerCanUpdate = "viewer_can_update"
    case viewerCanMergeAsAdmin = "viewer_can_merge_as_admin"
    case headSHA = "head_sha"
    case labels
    case checks
    case additions
    case deletions
    case updatedAt = "updated_at"
    case requiredFailedCheckNames = "required_failed_check_names"
  }
}

private struct MobileRemoteReviewCheckWire: Decodable, Sendable {
  var name: String
  var status: String
  var conclusion: String
  var checkSuiteID: String?
  var detailsURL: String?

  func mobileSnippet(
    reviewID: String,
    index: Int,
    redactor: MobileMirrorSecretRedactor
  ) -> MobileReviewCheckSnippet {
    MobileReviewCheckSnippet(
      id: "\(reviewID)-check-\(index)",
      name: redactor.redact(name),
      status: status,
      conclusion: conclusion,
      checkSuiteID: checkSuiteID,
      detailsURL: detailsURL.map(redactor.redact)
    )
  }

  enum CodingKeys: String, CodingKey {
    case name
    case status
    case conclusion
    case checkSuiteID = "check_suite_id"
    case detailsURL = "details_url"
  }
}

extension MobileReviewSummary {
  fileprivate func mobileAttention(
    stationID: String,
    redactor: MobileMirrorSecretRedactor
  ) -> MobileAttentionItem {
    MobileAttentionItem(
      id: "review-\(id)",
      stationID: stationID,
      kind: .pullRequest,
      severity: policyBlocked == true || checkStatus == "failure" ? .critical : .warning,
      title: redactor.redact("\(repository) #\(number) needs you"),
      subtitle: title,
      updatedAt: updatedAt,
      commandKind: checkStatus == "failure" ? .pullRequestRerunChecks : .pullRequestApprove,
      target: MobileCommandTarget(
        stationID: stationID,
        reviewID: id,
        targetRevision: 0
      ),
      commandPayload: [
        "repository": repository,
        "number": String(number),
        "headSha": headSha ?? "",
      ]
    )
  }
}
