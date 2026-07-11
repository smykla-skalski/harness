import Foundation
import Testing

@testable import HarnessMonitorKit

extension TaskBoardAPIClientTests {
  func performReviewsHTTPClientContractCalls() async throws
    -> ReviewsHTTPContractResult
  {
    TaskBoardURLProtocol.reset()
    let client = try makeClient()
    let target = reviewsTarget()

    let actions = try await performReviewsHTTPActionCalls(client: client, target: target)
    let policy = try await performReviewsHTTPPolicyCalls(client: client, target: target)

    return ReviewsHTTPContractResult(
      repositoryCatalog: actions.repositoryCatalog,
      capabilities: actions.capabilities,
      query: actions.query,
      preview: actions.preview,
      approve: actions.approve,
      merge: actions.merge,
      rerun: actions.rerun,
      label: actions.label,
      auto: actions.auto,
      policyPreview: policy.policyPreview,
      policyRun: policy.policyRun,
      policyStatus: policy.policyStatus,
      cacheClear: policy.cacheClear,
      refresh: policy.refresh,
      comment: policy.comment,
      avatar: policy.avatar,
      timeline: policy.timeline,
      resolve: policy.resolve
    )
  }

  private func performReviewsHTTPActionCalls(
    client: HarnessMonitorAPIClient,
    target: ReviewTarget
  ) async throws -> ReviewsWebSocketActionCalls {
    let repositoryCatalog = try await client.catalogReviewRepositories(
      request: ReviewsRepositoryCatalogRequest(organization: "example")
    )
    let capabilities = try await client.reviewsCapabilities()
    let query = try await client.queryReviews(
      request: ReviewsQueryRequest(
        authors: ["renovate[bot]"],
        organizations: ["example"],
        repositories: ["example/harness"],
        excludeRepositories: ["example/archive"],
        forceRefresh: true,
        cacheMaxAgeSeconds: 120
      )
    )
    let preview = try await client.previewReviewAction(
      request: ReviewsActionPreviewRequest(
        action: .merge,
        targets: [target],
        method: .rebase
      )
    )
    let approve = try await client.approveReviews(
      request: ReviewsApproveRequest(targets: [target], source: .direct)
    )
    let merge = try await client.mergeReviews(
      request: ReviewsMergeRequest(targets: [target], method: .rebase)
    )
    let rerun = try await client.rerunReviewChecks(
      request: ReviewsRerunChecksRequest(targets: [target])
    )
    let label = try await client.addReviewLabel(
      request: ReviewsLabelRequest(targets: [target], label: "dependencies:ready")
    )
    let auto = try await client.autoReviews(
      request: ReviewsAutoRequest(targets: [target], method: .squash)
    )
    return ReviewsWebSocketActionCalls(
      repositoryCatalog: repositoryCatalog,
      capabilities: capabilities,
      query: query,
      preview: preview,
      approve: approve,
      merge: merge,
      rerun: rerun,
      label: label,
      auto: auto
    )
  }

  private func performReviewsHTTPPolicyCalls(
    client: HarnessMonitorAPIClient,
    target: ReviewTarget
  ) async throws -> ReviewsWebSocketPolicyCalls {
    let policyPreview = try await client.previewReviewsPolicy(
      ReviewsPolicyPreviewRequest(
        target: target,
        method: .squash
      )
    )
    let policyRun = try await client.startReviewsPolicyRun(
      ReviewsPolicyRunStartRequest(
        target: target,
        method: .squash,
        trigger: .manual
      )
    )
    let policyStatus = try await client.reviewsPolicyStatus(
      ReviewsPolicyStatusRequest(target: target)
    )
    let cacheClear = try await client.clearReviewsCache()
    let refresh = try await client.refreshReviews(
      request: ReviewsRefreshRequest(targets: [target])
    )
    let comment = try await client.commentReviews(
      request: ReviewsCommentRequest(
        targets: [target],
        body: "@renovatebot rebase"
      )
    )
    let avatar = try await client.fetchReviewAvatar(
      request: ReviewsAvatarRequest(
        avatarURL: "https://avatars.githubusercontent.com/in/2740?v=4"
      )
    )
    let timeline = try await client.fetchReviewTimeline(
      request: ReviewsTimelineRequest(
        pullRequestId: target.pullRequestID,
        cursor: nil,
        pageSize: 50,
        direction: .older,
        forceRefresh: false,
        pullRequestUpdatedAt: "2026-05-21T09:00:00Z"
      )
    )
    let resolve = try await client.resolveReviewPullRequests(
      request: ReviewsPullRequestResolveRequest(
        references: [ReviewsPullRequestReference(repository: "example/harness", number: 42)]
      )
    )
    return ReviewsWebSocketPolicyCalls(
      policyPreview: policyPreview,
      policyRun: policyRun,
      policyStatus: policyStatus,
      cacheClear: cacheClear,
      refresh: refresh,
      comment: comment,
      avatar: avatar,
      timeline: timeline,
      resolve: resolve
    )
  }
}
