import Foundation

extension WebSocketTransport: ReviewsPolicyClientRouting {
  public func previewReviewsPolicy(
    _ request: ReviewsPolicyPreviewRequest
  ) async throws -> ReviewsPolicyPreviewResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsPolicyPreview, params: params)
    return try decode(value)
  }

  public func startReviewsPolicyRun(
    _ request: ReviewsPolicyRunStartRequest
  ) async throws -> ReviewsPolicyRunResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsPolicyStart, params: params)
    return try decode(value)
  }

  public func reviewsPolicyStatus(
    _ request: ReviewsPolicyStatusRequest
  ) async throws -> ReviewsPolicyStatusResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .reviewsPolicyStatus, params: params)
    return try decode(value)
  }
}

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
    let params = try encodeParams(ReviewsBodyUpdateRequestWire(request), extra: [:])
    let value = try await rpc(method: .reviewsBodyUpdate, params: params)
    let wire: ReviewsBodyUpdateResponseWire = try decodePolicyWire(value)
    return ReviewsBodyUpdateResponse(wire: wire)
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
    let params = try encodeParams(ReviewsFilesListRequestWire(request), extra: [:])
    let value = try await rpc(method: .reviewsFilesList, params: params)
    let wire: ReviewsFilesListResponseWire = try decodePolicyWire(value)
    return ReviewsFilesListResponse(wire: wire)
  }

  public func patchReviewFiles(
    request: ReviewsFilesPatchRequest
  ) async throws -> ReviewsFilesPatchResponse {
    let params = try encodeParams(ReviewsFilesPatchRequestWire(request), extra: [:])
    let value = try await rpc(method: .reviewsFilesPatch, params: params)
    let wire: ReviewsFilesPatchResponseWire = try decodePolicyWire(value)
    return ReviewsFilesPatchResponse(wire: wire)
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
    let params = try encodeParams(ReviewsAvatarRequestWire(request), extra: [:])
    let value = try await rpc(method: .reviewsAvatar, params: params)
    let wire: ReviewsAvatarResponseWire = try decodePolicyWire(value)
    return ReviewsAvatarResponse(wire: wire)
  }

  public func setReviewThreadResolved(
    request: ReviewsReviewThreadResolveRequest
  ) async throws -> ReviewsReviewThreadResolveResponse {
    let params = try encodeParams(ReviewsReviewThreadResolveRequestWire(request), extra: [:])
    let value = try await rpc(method: .reviewsReviewThreadsResolve, params: params)
    let wire: ReviewsReviewThreadResolveResponseWire = try decodePolicyWire(value)
    return ReviewsReviewThreadResolveResponse(wire: wire)
  }

  public func addReviewFileComment(
    request: ReviewsFileCommentRequest
  ) async throws -> ReviewsFileCommentResponse {
    let params = try encodeParams(ReviewsFileCommentRequestWire(request), extra: [:])
    let value = try await rpc(method: .reviewsFilesComment, params: params)
    let wire: ReviewsFileCommentResponseWire = try decodePolicyWire(value)
    return ReviewsFileCommentResponse(wire: wire)
  }
}
