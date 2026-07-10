import Foundation
import HarnessMonitorCore

struct MobileRemoteDaemonReviewReference: Equatable, Sendable {
  let repository: String
  let number: Int
}

struct MobileRemoteDaemonResolvedReviewTarget: Decodable, Sendable {
  private let pullRequestID: String
  private let repositoryID: String
  private let repository: String
  private let number: Int
  private let url: String
  private let state: String
  private let headSHA: String
  private let mergeable: String
  private let reviewStatus: String
  private let checkStatus: String
  private let isDraft: Bool?
  private let policyBlocked: Bool?
  private let viewerCanUpdate: Bool?
  private let viewerCanMergeAsAdmin: Bool?
  private let requiredFailedCheckNames: [String]?
  private let checks: [Check]?
  private let hasConflictMarkers: Bool?
  private let viewerHasActiveApproval: Bool?
  private let autoMergeEnabled: Bool?
  private let approvalSatisfiedAfterViewerApproval: Bool?

  var actionTarget: [String: Any] {
    var target: [String: Any] = [
      "pull_request_id": pullRequestID,
      "repository_id": repositoryID,
      "repository": repository,
      "number": number,
      "url": url,
      "state": state,
      "head_sha": headSHA,
      "mergeable": mergeable,
      "review_status": reviewStatus,
      "check_status": checkStatus,
      "is_draft": isDraft ?? false,
      "policy_blocked": policyBlocked ?? false,
      "viewer_can_update": viewerCanUpdate ?? true,
      "viewer_can_merge_as_admin": viewerCanMergeAsAdmin ?? false,
      "required_failed_check_names": requiredFailedCheckNames ?? [],
      "check_suite_ids": checkSuiteIDs,
    ]
    target.add("has_conflict_markers", hasConflictMarkers)
    target.add("viewer_has_active_approval", viewerHasActiveApproval)
    target.add("auto_merge_enabled", autoMergeEnabled)
    target.add(
      "approval_requirement_satisfied_after_viewer_approval",
      approvalSatisfiedAfterViewerApproval
    )
    return target
  }

  func matches(_ reference: MobileRemoteDaemonReviewReference) -> Bool {
    number == reference.number
      && repository.caseInsensitiveCompare(reference.repository) == .orderedSame
  }

  private var checkSuiteIDs: [String] {
    var seen = Set<String>()
    return (checks ?? []).compactMap(\.checkSuiteID).filter { seen.insert($0).inserted }
  }

  private struct Check: Decodable, Sendable {
    let checkSuiteID: String?

    enum CodingKeys: String, CodingKey {
      case checkSuiteID = "check_suite_id"
    }
  }

  enum CodingKeys: String, CodingKey {
    case pullRequestID = "pull_request_id"
    case repositoryID = "repository_id"
    case repository
    case number
    case url
    case state
    case headSHA = "head_sha"
    case mergeable
    case reviewStatus = "review_status"
    case checkStatus = "check_status"
    case isDraft = "is_draft"
    case policyBlocked = "policy_blocked"
    case viewerCanUpdate = "viewer_can_update"
    case viewerCanMergeAsAdmin = "viewer_can_merge_as_admin"
    case requiredFailedCheckNames = "required_failed_check_names"
    case checks
    case hasConflictMarkers = "has_conflict_markers"
    case viewerHasActiveApproval = "viewer_has_active_approval"
    case autoMergeEnabled = "auto_merge_enabled"
    case approvalSatisfiedAfterViewerApproval =
      "approval_requirement_satisfied_after_viewer_approval"
  }
}

extension MobileRemoteDaemonSyncClient {
  func resolvedReviewTarget(
    for command: MobileCommandRecord
  ) async throws -> MobileRemoteDaemonResolvedReviewTarget? {
    guard
      let reference = try MobileRemoteDaemonCommandRequestBuilder.reviewReference(command)
    else {
      return nil
    }
    let body = try MobileRemoteDaemonCommandRequestBuilder.jsonBody([
      "references": [["repository": reference.repository, "number": reference.number]],
      "backport_detection_enabled": true,
    ])
    var request = try authenticatedRequest(
      path: "/v1/reviews/pull-requests/resolve",
      method: "POST"
    )
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MobileRemoteDaemonSyncError.invalidResponse
    }
    try validate(response)
    guard let result = try? JSONDecoder().decode(ResolveResponse.self, from: data) else {
      throw MobileRemoteDaemonSyncError.invalidResponse
    }
    guard let target = result.items.first(where: { $0.matches(reference) }) else {
      throw MobileRemoteDaemonSyncError.invalidCommand(
        "remote daemon did not resolve \(reference.repository)#\(reference.number)"
      )
    }
    return target
  }
}

private struct ResolveResponse: Decodable {
  let items: [MobileRemoteDaemonResolvedReviewTarget]
}
