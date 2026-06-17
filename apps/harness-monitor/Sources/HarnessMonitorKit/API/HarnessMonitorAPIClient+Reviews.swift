import Foundation

extension HarnessMonitorAPIClient: ReviewsPolicyClientRouting {
  public func previewReviewsPolicy(
    _ request: ReviewsPolicyPreviewRequest
  ) async throws -> ReviewsPolicyPreviewResponse {
    try await post("/v1/reviews/policy/preview", body: request)
  }

  public func startReviewsPolicyRun(
    _ request: ReviewsPolicyRunStartRequest
  ) async throws -> ReviewsPolicyRunResponse {
    try await post("/v1/reviews/policy/start", body: request)
  }

  public func reviewsPolicyStatus(
    _ request: ReviewsPolicyStatusRequest
  ) async throws -> ReviewsPolicyStatusResponse {
    try await post("/v1/reviews/policy/status", body: request)
  }

  public func reviewsPolicyHistory(
    _ request: ReviewsPolicyHistoryRequest
  ) async throws -> ReviewsPolicyHistoryResponse {
    try await post("/v1/reviews/policy/history", body: request)
  }
}

extension HarnessMonitorAPIClient {
  public func catalogReviewRepositories(
    request: ReviewsRepositoryCatalogRequest
  ) async throws -> ReviewsRepositoryCatalogResponse {
    let wire: ReviewsRepositoryCatalogResponseWire = try await post(
      "/v1/reviews/repositories",
      body: ReviewsRepositoryCatalogRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsRepositoryCatalogResponse(wire: wire)
  }

  public func queryReviews(
    request: ReviewsQueryRequest
  ) async throws -> ReviewsQueryResponse {
    let wire: ReviewsQueryResponseWire = try await post(
      "/v1/reviews/query",
      body: ReviewsQueryRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsQueryResponse(wire: wire)
  }

  public func reviewsCapabilities() async throws -> ReviewsCapabilitiesResponse {
    let wire: ReviewsCapabilitiesResponseWire = try await get(
      "/v1/reviews/capabilities",
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsCapabilitiesResponse(wire: wire)
  }

  public func previewReviewAction(
    request: ReviewsActionPreviewRequest
  ) async throws -> ReviewsActionPreviewResponse {
    let wire: ReviewsActionPreviewResponseWire = try await post(
      "/v1/reviews/action-preview",
      body: ReviewsActionPreviewRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsActionPreviewResponse(wire: wire)
  }

  public func approveReviews(
    request: ReviewsApproveRequest
  ) async throws -> ReviewsActionResponse {
    let wire: ReviewsActionResponseWire = try await post(
      "/v1/reviews/approve",
      body: ReviewsApproveRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsActionResponse(wire: wire)
  }

  public func mergeReviews(
    request: ReviewsMergeRequest
  ) async throws -> ReviewsActionResponse {
    let wire: ReviewsActionResponseWire = try await post(
      "/v1/reviews/merge",
      body: ReviewsMergeRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsActionResponse(wire: wire)
  }

  public func rerunReviewChecks(
    request: ReviewsRerunChecksRequest
  ) async throws -> ReviewsActionResponse {
    let wire: ReviewsActionResponseWire = try await post(
      "/v1/reviews/rerun-checks",
      body: ReviewsRerunChecksRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsActionResponse(wire: wire)
  }

  public func addReviewLabel(
    request: ReviewsLabelRequest
  ) async throws -> ReviewsActionResponse {
    let wire: ReviewsActionResponseWire = try await post(
      "/v1/reviews/labels",
      body: ReviewsLabelRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsActionResponse(wire: wire)
  }

  public func autoReviews(
    request: ReviewsAutoRequest
  ) async throws -> ReviewsActionResponse {
    let wire: ReviewsActionResponseWire = try await post(
      "/v1/reviews/auto",
      body: ReviewsAutoRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsActionResponse(wire: wire)
  }

  public func reRequestReview(
    request: ReviewsRequestReviewRequest
  ) async throws -> ReviewsActionResponse {
    let wire: ReviewsActionResponseWire = try await post(
      "/v1/reviews/request-review",
      body: ReviewsRequestReviewRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsActionResponse(wire: wire)
  }

  public func clearReviewsCache() async throws -> ReviewsCacheClearResponse {
    let wire: ReviewsCacheClearResponseWire = try await delete(
      "/v1/reviews/cache",
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsCacheClearResponse(wire: wire)
  }

  public func refreshReviews(
    request: ReviewsRefreshRequest
  ) async throws -> ReviewsRefreshResponse {
    let wire: ReviewsRefreshResponseWire = try await post(
      "/v1/reviews/refresh",
      body: ReviewsRefreshRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsRefreshResponse(wire: wire)
  }

  public func fetchReviewBody(
    request: ReviewsBodyRequest
  ) async throws -> ReviewsBodyResponse {
    let wire: ReviewsBodyResponseWire = try await post(
      "/v1/reviews/body",
      body: ReviewsBodyRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsBodyResponse(wire: wire)
  }

  public func updateReviewBody(
    request: ReviewsBodyUpdateRequest
  ) async throws -> ReviewsBodyUpdateResponse {
    let wire: ReviewsBodyUpdateResponseWire = try await post(
      "/v1/reviews/body/update",
      body: ReviewsBodyUpdateRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsBodyUpdateResponse(wire: wire)
  }

  public func commentReviews(
    request: ReviewsCommentRequest
  ) async throws -> ReviewsActionResponse {
    let wire: ReviewsActionResponseWire = try await post(
      "/v1/reviews/comment",
      body: ReviewsCommentRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsActionResponse(wire: wire)
  }

  public func listReviewFiles(
    request: ReviewsFilesListRequest
  ) async throws -> ReviewsFilesListResponse {
    let wire: ReviewsFilesListResponseWire = try await post(
      "/v1/reviews/files/list",
      body: ReviewsFilesListRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsFilesListResponse(wire: wire)
  }

  public func patchReviewFiles(
    request: ReviewsFilesPatchRequest
  ) async throws -> ReviewsFilesPatchResponse {
    let wire: ReviewsFilesPatchResponseWire = try await post(
      "/v1/reviews/files/patch",
      body: ReviewsFilesPatchRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsFilesPatchResponse(wire: wire)
  }

  public func previewReviewFiles(
    request: ReviewsFilesPreviewRequest
  ) async throws -> ReviewsFilesPreviewResponse {
    let wire: ReviewsFilesPreviewResponseWire = try await post(
      "/v1/reviews/files/preview",
      body: ReviewsFilesPreviewRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsFilesPreviewResponse(wire: wire)
  }

  public func viewedReviewFiles(
    request: ReviewsFilesViewedRequest
  ) async throws -> ReviewsFilesViewedResponse {
    let wire: ReviewsFilesViewedResponseWire = try await post(
      "/v1/reviews/files/viewed",
      body: ReviewsFilesViewedRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsFilesViewedResponse(wire: wire)
  }

  public func fetchReviewFileBlob(
    request: ReviewsFilesBlobRequest
  ) async throws -> ReviewsFilesBlobResponse {
    let wire: ReviewsFilesBlobResponseWire = try await post(
      "/v1/reviews/files/blob",
      body: ReviewsFilesBlobRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsFilesBlobResponse(wire: wire)
  }

  public func listReviewLocalClones() async throws -> [ReviewLocalCloneEntry] {
    let wire: [LocalCloneListEntryWire] = try await post(
      "/v1/reviews/files/local-clones",
      body: ReviewsFilesLocalClonesListRequest(),
      decoder: PolicyWireCoding.decoder
    )
    return wire.map(ReviewLocalCloneEntry.init(wire:))
  }

  public func deleteReviewLocalClone(repoKeySegment: String) async throws {
    let body = ReviewsFilesLocalClonesDeleteRequest(repoKeySegment: repoKeySegment)
    // The daemon returns the post-delete listing, but the Settings sheet
    // refetches via listReviewLocalClones, so the body is decoded structurally
    // and discarded rather than through a convert-bound hand mirror.
    let _: JSONValue = try await post("/v1/reviews/files/local-clones/delete", body: body)
  }

  public func fetchReviewTimeline(
    request: ReviewsTimelineRequest
  ) async throws -> ReviewsTimelineResponse {
    let wire: ReviewsTimelineResponseWire = try await post(
      "/v1/reviews/timeline",
      body: ReviewsTimelineRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsTimelineResponse(wire: wire)
  }

  public func fetchReviewAvatar(
    request: ReviewsAvatarRequest
  ) async throws -> ReviewsAvatarResponse {
    let wire: ReviewsAvatarResponseWire = try await post(
      "/v1/reviews/avatar",
      body: ReviewsAvatarRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsAvatarResponse(wire: wire)
  }

  public func setReviewThreadResolved(
    request: ReviewsReviewThreadResolveRequest
  ) async throws -> ReviewsReviewThreadResolveResponse {
    let wire: ReviewsReviewThreadResolveResponseWire = try await post(
      "/v1/reviews/review-threads/resolve",
      body: ReviewsReviewThreadResolveRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsReviewThreadResolveResponse(wire: wire)
  }

  public func addReviewFileComment(
    request: ReviewsFileCommentRequest
  ) async throws -> ReviewsFileCommentResponse {
    let wire: ReviewsFileCommentResponseWire = try await post(
      "/v1/reviews/files/comment",
      body: ReviewsFileCommentRequestWire(request),
      decoder: PolicyWireCoding.decoder
    )
    return ReviewsFileCommentResponse(wire: wire)
  }
}

/// Empty request body for listing local clones. The daemon does not need
/// any parameters but the HTTP route expects a POST so we send an empty
/// payload to satisfy the contract.
public struct ReviewsFilesLocalClonesListRequest: Codable, Equatable, Sendable {
  public init() {}
}

/// Request body for deleting a single local clone by repo key segment.
public struct ReviewsFilesLocalClonesDeleteRequest: Codable, Equatable, Sendable {
  public let repoKeySegment: String

  public init(repoKeySegment: String) {
    self.repoKeySegment = repoKeySegment
  }

  enum CodingKeys: String, CodingKey {
    case repoKeySegment = "repo_key_segment"
  }
}
