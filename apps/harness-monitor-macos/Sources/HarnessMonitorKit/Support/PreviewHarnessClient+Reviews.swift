import Foundation

extension PreviewHarnessClient {
  public func catalogReviewRepositories(
    request: ReviewsRepositoryCatalogRequest
  ) async throws -> ReviewsRepositoryCatalogResponse {
    try await performActionDelay()
    return await state.catalogReviewRepositories(request: request)
  }

  public func queryReviews(
    request: ReviewsQueryRequest
  ) async throws -> ReviewsQueryResponse {
    try await performActionDelay()
    return await state.currentReviews(request: request)
  }

  public func reviewsCapabilities() async throws -> ReviewsCapabilitiesResponse {
    try await performActionDelay()
    return ReviewsCapabilitiesResponse()
  }

  public func previewReviewAction(
    request: ReviewsActionPreviewRequest
  ) async throws -> ReviewsActionPreviewResponse {
    try await performActionDelay()
    return await state.previewReviewAction(request: request)
  }

  public func approveReviews(
    request: ReviewsApproveRequest
  ) async throws -> ReviewsActionResponse {
    try await performActionDelay()
    return await state.approveReviews(request: request)
  }

  public func mergeReviews(
    request: ReviewsMergeRequest
  ) async throws -> ReviewsActionResponse {
    try await performActionDelay()
    return await state.mergeReviews(request: request)
  }

  public func rerunReviewChecks(
    request: ReviewsRerunChecksRequest
  ) async throws -> ReviewsActionResponse {
    try await performActionDelay()
    return await state.rerunReviewChecks(request: request)
  }

  public func addReviewLabel(
    request: ReviewsLabelRequest
  ) async throws -> ReviewsActionResponse {
    try await performActionDelay()
    return await state.addReviewLabel(request: request)
  }

  public func autoReviews(
    request: ReviewsAutoRequest
  ) async throws -> ReviewsActionResponse {
    try await performActionDelay()
    return await state.autoReviews(request: request)
  }

  public func clearReviewsCache() async throws -> ReviewsCacheClearResponse {
    try await performActionDelay()
    return await state.clearReviewsCache()
  }

  public func refreshReviews(
    request: ReviewsRefreshRequest
  ) async throws -> ReviewsRefreshResponse {
    try await performActionDelay()
    return await state.refreshReviews(request: request)
  }

  public func fetchReviewBody(
    request: ReviewsBodyRequest
  ) async throws -> ReviewsBodyResponse {
    try await performActionDelay()
    return await state.fetchReviewBody(request: request)
  }

  public func updateReviewBody(
    request: ReviewsBodyUpdateRequest
  ) async throws -> ReviewsBodyUpdateResponse {
    try await performActionDelay()
    return await state.updateReviewBody(request: request)
  }

  public func commentReviews(
    request: ReviewsCommentRequest
  ) async throws -> ReviewsActionResponse {
    try await performActionDelay()
    return await state.commentReviews(request: request)
  }

  public func addReviewFileComment(
    request: ReviewsFileCommentRequest
  ) async throws -> ReviewsFileCommentResponse {
    try await performActionDelay()
    return await state.addReviewFileComment(request: request)
  }

  public func listReviewFiles(
    request: ReviewsFilesListRequest
  ) async throws -> ReviewsFilesListResponse {
    try await performActionDelay()
    return await state.listReviewFiles(request: request)
  }

  public func patchReviewFiles(
    request: ReviewsFilesPatchRequest
  ) async throws -> ReviewsFilesPatchResponse {
    try await performActionDelay()
    return await state.patchReviewFiles(request: request)
  }

  public func previewReviewFiles(
    request: ReviewsFilesPreviewRequest
  ) async throws -> ReviewsFilesPreviewResponse {
    try await performActionDelay()
    return await state.previewReviewFiles(request: request)
  }

  public func viewedReviewFiles(
    request: ReviewsFilesViewedRequest
  ) async throws -> ReviewsFilesViewedResponse {
    try await performActionDelay()
    return await state.viewedReviewFiles(request: request)
  }

  public func fetchReviewFileBlob(
    request: ReviewsFilesBlobRequest
  ) async throws -> ReviewsFilesBlobResponse {
    try await performActionDelay()
    return await state.fetchReviewFileBlob(request: request)
  }

  public func listReviewLocalClones() async throws -> [ReviewLocalCloneEntry] {
    try await performActionDelay()
    return await state.listReviewLocalClones()
  }

  public func deleteReviewLocalClone(repoKeySegment: String) async throws {
    try await performActionDelay()
    await state.deleteReviewLocalClone(repoKeySegment: repoKeySegment)
  }
}
