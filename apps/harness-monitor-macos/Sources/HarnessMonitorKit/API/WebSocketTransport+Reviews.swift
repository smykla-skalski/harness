import Foundation

extension WebSocketTransport {
  public func catalogReviewRepositories(
    request: ReviewsRepositoryCatalogRequest
  ) async throws -> ReviewsRepositoryCatalogResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsRepositoryCatalog, params: params)
    return try decode(value)
  }

  public func queryReviews(
    request: ReviewsQueryRequest
  ) async throws -> ReviewsQueryResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsQuery, params: params)
    return try decode(value)
  }

  public func reviewsCapabilities() async throws -> ReviewsCapabilitiesResponse {
    let value = try await rpc(method: .reviewsCapabilities, params: nil)
    return try decode(value)
  }

  public func previewReviewAction(
    request: ReviewsActionPreviewRequest
  ) async throws -> ReviewsActionPreviewResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsActionPreview, params: params)
    return try decode(value)
  }

  public func approveReviews(
    request: ReviewsApproveRequest
  ) async throws -> ReviewsActionResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsApprove, params: params)
    return try decode(value)
  }

  public func mergeReviews(
    request: ReviewsMergeRequest
  ) async throws -> ReviewsActionResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsMerge, params: params)
    return try decode(value)
  }

  public func rerunReviewChecks(
    request: ReviewsRerunChecksRequest
  ) async throws -> ReviewsActionResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsRerunChecks, params: params)
    return try decode(value)
  }

  public func addReviewLabel(
    request: ReviewsLabelRequest
  ) async throws -> ReviewsActionResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsAddLabel, params: params)
    return try decode(value)
  }

  public func autoReviews(
    request: ReviewsAutoRequest
  ) async throws -> ReviewsActionResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsAuto, params: params)
    return try decode(value)
  }

  public func reRequestReview(
    request: ReviewsRequestReviewRequest
  ) async throws -> ReviewsActionResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsRequestReview, params: params)
    return try decode(value)
  }

  public func clearReviewsCache() async throws -> ReviewsCacheClearResponse {
    let value = try await rpc(method: .reviewsClearCache, params: nil)
    return try decode(value)
  }

  public func refreshReviews(
    request: ReviewsRefreshRequest
  ) async throws -> ReviewsRefreshResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsRefresh, params: params)
    return try decode(value)
  }

  public func fetchReviewBody(
    request: ReviewsBodyRequest
  ) async throws -> ReviewsBodyResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsBody, params: params)
    return try decode(value)
  }

  public func updateReviewBody(
    request: ReviewsBodyUpdateRequest
  ) async throws -> ReviewsBodyUpdateResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsBodyUpdate, params: params)
    return try decode(value)
  }

  public func commentReviews(
    request: ReviewsCommentRequest
  ) async throws -> ReviewsActionResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsComment, params: params)
    return try decode(value)
  }

  public func listReviewFiles(
    request: ReviewsFilesListRequest
  ) async throws -> ReviewsFilesListResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsFilesList, params: params)
    return try decode(value)
  }

  public func patchReviewFiles(
    request: ReviewsFilesPatchRequest
  ) async throws -> ReviewsFilesPatchResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsFilesPatch, params: params)
    return try decode(value)
  }

  public func previewReviewFiles(
    request: ReviewsFilesPreviewRequest
  ) async throws -> ReviewsFilesPreviewResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsFilesPreview, params: params)
    return try decode(value)
  }

  public func viewedReviewFiles(
    request: ReviewsFilesViewedRequest
  ) async throws -> ReviewsFilesViewedResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsFilesViewed, params: params)
    return try decode(value)
  }

  public func fetchReviewFileBlob(
    request: ReviewsFilesBlobRequest
  ) async throws -> ReviewsFilesBlobResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsFilesBlob, params: params)
    return try decode(value)
  }

  public func listReviewLocalClones() async throws -> [ReviewLocalCloneEntry] {
    let value = try await rpc(method: .reviewsFilesLocalClonesList, params: nil)
    return try decode(value)
  }

  public func deleteReviewLocalClone(repoKeySegment: String) async throws {
    let request = ReviewsFilesLocalClonesDeleteRequest(repoKeySegment: repoKeySegment)
    let params = try encodeParams(request, extra: [:])
    _ = try await rpc(method: .reviewsFilesLocalClonesDelete, params: params)
  }

  public func fetchReviewTimeline(
    request: ReviewsTimelineRequest
  ) async throws -> ReviewsTimelineResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsTimeline, params: params)
    return try decode(value)
  }

  public func fetchReviewAvatar(
    request: ReviewsAvatarRequest
  ) async throws -> ReviewsAvatarResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsAvatar, params: params)
    return try decode(value)
  }

  public func setReviewThreadResolved(
    request: ReviewsReviewThreadResolveRequest
  ) async throws -> ReviewsReviewThreadResolveResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsReviewThreadsResolve, params: params)
    return try decode(value)
  }
}
