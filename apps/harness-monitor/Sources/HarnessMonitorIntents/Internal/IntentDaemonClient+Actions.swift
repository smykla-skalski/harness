import Foundation
import HarnessMonitorKit

extension IntentDaemonClient {
  public func approve(pullRequestID: String) async throws {
    let target = try await resolveReviewTarget(pullRequestID: pullRequestID)
    try await runActionRPC(method: "reviews.approve") {
      _ = try await self.transport.approveReviews(
        request: ReviewsApproveRequest(targets: [target])
      )
    }
  }

  public func merge(
    pullRequestID: String,
    method: TaskBoardGitHubMergeMethod
  ) async throws {
    let target = try await resolveReviewTarget(pullRequestID: pullRequestID)
    try await runActionRPC(method: "reviews.merge") {
      _ = try await self.transport.mergeReviews(
        request: ReviewsMergeRequest(targets: [target], method: method)
      )
    }
  }

  public func rerunChecks(pullRequestID: String) async throws {
    let target = try await resolveReviewTarget(pullRequestID: pullRequestID)
    try await runActionRPC(method: "reviews.rerun_checks") {
      _ = try await self.transport.rerunReviewChecks(
        request: ReviewsRerunChecksRequest(targets: [target])
      )
    }
  }

  public func addLabel(pullRequestID: String, label: String) async throws {
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedLabel.isEmpty else {
      throw IntentDaemonError.rpcFailed(
        method: "reviews.label",
        message: "Label must not be blank"
      )
    }
    let target = try await resolveReviewTarget(pullRequestID: pullRequestID)
    try await runActionRPC(method: "reviews.label") {
      _ = try await self.transport.addReviewLabel(
        request: ReviewsLabelRequest(targets: [target], label: trimmedLabel)
      )
    }
  }

  func resolveReviewTarget(pullRequestID: String) async throws -> ReviewTarget {
    let response = try await queryReviewsCurrentSnapshot()
    guard let item = response.items.first(where: { $0.pullRequestID == pullRequestID }) else {
      throw IntentDaemonError.rpcFailed(
        method: "reviews.query",
        message: "Pull request \(pullRequestID) not found in the current snapshot"
      )
    }
    return Self.reviewTarget(from: item)
  }

  static func reviewTarget(from item: ReviewItem) -> ReviewTarget {
    let checkSuiteIDs = Array(Set(item.checks.compactMap(\.checkSuiteID)))
    return ReviewTarget(
      pullRequestID: item.pullRequestID,
      repositoryID: item.repositoryID,
      repository: item.repository,
      number: item.number,
      url: item.url,
      state: item.state,
      isDraft: item.isDraft,
      headSha: item.headSha,
      mergeable: item.mergeable,
      reviewStatus: item.reviewStatus,
      checkStatus: item.checkStatus,
      policyBlocked: item.policyBlocked,
      requiredFailedCheckNames: item.requiredFailedCheckNames,
      viewerCanMergeAsAdmin: item.viewerCanMergeAsAdmin,
      checkSuiteIDs: checkSuiteIDs,
      viewerCanUpdate: item.viewerCanUpdate
    )
  }

  private func runActionRPC(
    method: String,
    body: () async throws -> Void
  ) async throws {
    do {
      try await body()
    } catch let error as IntentDaemonError {
      throw error
    } catch {
      throw IntentDaemonError.rpcFailed(method: method, message: error.localizedDescription)
    }
  }
}
