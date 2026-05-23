import Foundation

public protocol HarnessMonitorReviewsClientProtocol: Sendable {
  func catalogReviewRepositories(
    request: ReviewsRepositoryCatalogRequest
  ) async throws -> ReviewsRepositoryCatalogResponse
  func reviewsCapabilities() async throws -> ReviewsCapabilitiesResponse
  func queryReviews(
    request: ReviewsQueryRequest
  ) async throws -> ReviewsQueryResponse
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
}
