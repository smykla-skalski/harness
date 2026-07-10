import Foundation

protocol ReviewsPolicyClientRouting: Sendable {
  func previewReviewsPolicy(_ request: ReviewsPolicyPreviewRequest) async throws
    -> ReviewsPolicyPreviewResponse
  func startReviewsPolicyRun(_ request: ReviewsPolicyRunStartRequest) async throws
    -> ReviewsPolicyRunResponse
  func reviewsPolicyStatus(_ request: ReviewsPolicyStatusRequest) async throws
    -> ReviewsPolicyStatusResponse
  func reviewsPolicyHistory(_ request: ReviewsPolicyHistoryRequest) async throws
    -> ReviewsPolicyHistoryResponse
}

extension HarnessMonitorReviewsClientProtocol {
  public func previewReviewsPolicy(_ request: ReviewsPolicyPreviewRequest) async throws
    -> ReviewsPolicyPreviewResponse
  {
    guard let client = self as? any ReviewsPolicyClientRouting else {
      throw HarnessMonitorAPIError.server(
        code: 501, message: "Reviews policy preview is not available.")
    }
    return try await client.previewReviewsPolicy(request)
  }

  public func startReviewsPolicyRun(_ request: ReviewsPolicyRunStartRequest) async throws
    -> ReviewsPolicyRunResponse
  {
    guard let client = self as? any ReviewsPolicyClientRouting else {
      throw HarnessMonitorAPIError.server(
        code: 501, message: "Reviews policy execution is not available.")
    }
    return try await client.startReviewsPolicyRun(request)
  }

  public func reviewsPolicyStatus(_ request: ReviewsPolicyStatusRequest) async throws
    -> ReviewsPolicyStatusResponse
  {
    guard let client = self as? any ReviewsPolicyClientRouting else {
      throw HarnessMonitorAPIError.server(
        code: 501, message: "Reviews policy status is not available.")
    }
    return try await client.reviewsPolicyStatus(request)
  }

  public func reviewsPolicyHistory(_ request: ReviewsPolicyHistoryRequest) async throws
    -> ReviewsPolicyHistoryResponse
  {
    guard let client = self as? any ReviewsPolicyClientRouting else {
      throw HarnessMonitorAPIError.server(
        code: 501, message: "Reviews policy history is not available.")
    }
    return try await client.reviewsPolicyHistory(request)
  }
}

public protocol HarnessMonitorReviewsClientProtocol: Sendable {
  func catalogReviewRepositories(
    request: ReviewsRepositoryCatalogRequest
  ) async throws -> ReviewsRepositoryCatalogResponse
  func reviewsCapabilities() async throws -> ReviewsCapabilitiesResponse
  func queryReviews(
    request: ReviewsQueryRequest
  ) async throws -> ReviewsQueryResponse
  func resolveReviewPullRequests(
    request: ReviewsPullRequestResolveRequest
  ) async throws -> ReviewsPullRequestResolveResponse
  func previewReviewAction(
    request: ReviewsActionPreviewRequest
  ) async throws -> ReviewsActionPreviewResponse
  func approveReviews(
    request: ReviewsApproveRequest
  ) async throws -> ReviewsActionResponse
  func mergeReviews(
    request: ReviewsMergeRequest
  ) async throws -> ReviewsActionResponse
  func rerunReviewChecks(
    request: ReviewsRerunChecksRequest
  ) async throws -> ReviewsActionResponse
  func addReviewLabel(
    request: ReviewsLabelRequest
  ) async throws -> ReviewsActionResponse
  func autoReviews(
    request: ReviewsAutoRequest
  ) async throws -> ReviewsActionResponse
  func reRequestReview(
    request: ReviewsRequestReviewRequest
  ) async throws -> ReviewsActionResponse
  func clearReviewsCache() async throws -> ReviewsCacheClearResponse
  func refreshReviews(
    request: ReviewsRefreshRequest
  ) async throws -> ReviewsRefreshResponse
  func fetchReviewBody(
    request: ReviewsBodyRequest
  ) async throws -> ReviewsBodyResponse
  func updateReviewBody(
    request: ReviewsBodyUpdateRequest
  ) async throws -> ReviewsBodyUpdateResponse
  func commentReviews(
    request: ReviewsCommentRequest
  ) async throws -> ReviewsActionResponse
  func listReviewFiles(
    request: ReviewsFilesListRequest
  ) async throws -> ReviewsFilesListResponse
  func patchReviewFiles(
    request: ReviewsFilesPatchRequest
  ) async throws -> ReviewsFilesPatchResponse
  func previewReviewFiles(
    request: ReviewsFilesPreviewRequest
  ) async throws -> ReviewsFilesPreviewResponse
  func viewedReviewFiles(
    request: ReviewsFilesViewedRequest
  ) async throws -> ReviewsFilesViewedResponse
  func fetchReviewFileBlob(
    request: ReviewsFilesBlobRequest
  ) async throws -> ReviewsFilesBlobResponse
  func listReviewLocalClones() async throws -> [ReviewLocalCloneEntry]
  func deleteReviewLocalClone(
    repoKeySegment: String
  ) async throws
  func fetchReviewTimeline(
    request: ReviewsTimelineRequest
  ) async throws -> ReviewsTimelineResponse
  func fetchReviewAvatar(
    request: ReviewsAvatarRequest
  ) async throws -> ReviewsAvatarResponse
  func setReviewThreadResolved(
    request: ReviewsReviewThreadResolveRequest
  ) async throws -> ReviewsReviewThreadResolveResponse
  func addReviewFileComment(
    request: ReviewsFileCommentRequest
  ) async throws -> ReviewsFileCommentResponse
}

extension HarnessMonitorReviewsClientProtocol {
  public func catalogReviewRepositories(
    request _: ReviewsRepositoryCatalogRequest
  ) async throws -> ReviewsRepositoryCatalogResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func queryReviews(
    request _: ReviewsQueryRequest
  ) async throws -> ReviewsQueryResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func resolveReviewPullRequests(
    request _: ReviewsPullRequestResolveRequest
  ) async throws -> ReviewsPullRequestResolveResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func reviewsCapabilities()
    async throws -> ReviewsCapabilitiesResponse
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func previewReviewAction(
    request _: ReviewsActionPreviewRequest
  ) async throws -> ReviewsActionPreviewResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func approveReviews(
    request _: ReviewsApproveRequest
  ) async throws -> ReviewsActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func mergeReviews(
    request _: ReviewsMergeRequest
  ) async throws -> ReviewsActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func rerunReviewChecks(
    request _: ReviewsRerunChecksRequest
  ) async throws -> ReviewsActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func addReviewLabel(
    request _: ReviewsLabelRequest
  ) async throws -> ReviewsActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func autoReviews(
    request _: ReviewsAutoRequest
  ) async throws -> ReviewsActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func reRequestReview(
    request _: ReviewsRequestReviewRequest
  ) async throws -> ReviewsActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func clearReviewsCache() async throws -> ReviewsCacheClearResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func refreshReviews(
    request _: ReviewsRefreshRequest
  ) async throws -> ReviewsRefreshResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func fetchReviewBody(
    request _: ReviewsBodyRequest
  ) async throws -> ReviewsBodyResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func updateReviewBody(
    request _: ReviewsBodyUpdateRequest
  ) async throws -> ReviewsBodyUpdateResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func commentReviews(
    request _: ReviewsCommentRequest
  ) async throws -> ReviewsActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func listReviewFiles(
    request _: ReviewsFilesListRequest
  ) async throws -> ReviewsFilesListResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func patchReviewFiles(
    request _: ReviewsFilesPatchRequest
  ) async throws -> ReviewsFilesPatchResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func previewReviewFiles(
    request _: ReviewsFilesPreviewRequest
  ) async throws -> ReviewsFilesPreviewResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func viewedReviewFiles(
    request _: ReviewsFilesViewedRequest
  ) async throws -> ReviewsFilesViewedResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func fetchReviewFileBlob(
    request _: ReviewsFilesBlobRequest
  ) async throws -> ReviewsFilesBlobResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func listReviewLocalClones() async throws -> [ReviewLocalCloneEntry] {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func deleteReviewLocalClone(repoKeySegment _: String) async throws {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func fetchReviewTimeline(
    request _: ReviewsTimelineRequest
  ) async throws -> ReviewsTimelineResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func fetchReviewAvatar(
    request _: ReviewsAvatarRequest
  ) async throws -> ReviewsAvatarResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func setReviewThreadResolved(
    request _: ReviewsReviewThreadResolveRequest
  ) async throws -> ReviewsReviewThreadResolveResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }

  public func addReviewFileComment(
    request _: ReviewsFileCommentRequest
  ) async throws -> ReviewsFileCommentResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Reviews unavailable")
  }
}
