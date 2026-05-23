import Foundation

extension HarnessMonitorAPIClient {
  public func catalogReviewRepositories(
    request: ReviewsRepositoryCatalogRequest
  ) async throws -> ReviewsRepositoryCatalogResponse {
    try await post("/v1/reviews/repositories", body: request)
  }

  public func queryReviews(
    request: ReviewsQueryRequest
  ) async throws -> ReviewsQueryResponse {
    try await post("/v1/reviews/query", body: request)
  }

  public func reviewsCapabilities() async throws -> ReviewsCapabilitiesResponse {
    try await get("/v1/reviews/capabilities")
  }

  public func previewReviewAction(
    request: ReviewsActionPreviewRequest
  ) async throws -> ReviewsActionPreviewResponse {
    try await post("/v1/reviews/action-preview", body: request)
  }

  public func approveReviews(
    request: ReviewsApproveRequest
  ) async throws -> ReviewsActionResponse {
    try await post("/v1/reviews/approve", body: request)
  }

  public func mergeReviews(
    request: ReviewsMergeRequest
  ) async throws -> ReviewsActionResponse {
    try await post("/v1/reviews/merge", body: request)
  }

  public func rerunReviewChecks(
    request: ReviewsRerunChecksRequest
  ) async throws -> ReviewsActionResponse {
    try await post("/v1/reviews/rerun-checks", body: request)
  }

  public func addReviewLabel(
    request: ReviewsLabelRequest
  ) async throws -> ReviewsActionResponse {
    try await post("/v1/reviews/labels", body: request)
  }

  public func autoReviews(
    request: ReviewsAutoRequest
  ) async throws -> ReviewsActionResponse {
    try await post("/v1/reviews/auto", body: request)
  }

  public func clearReviewsCache() async throws -> ReviewsCacheClearResponse {
    try await delete("/v1/reviews/cache")
  }

  public func refreshReviews(
    request: ReviewsRefreshRequest
  ) async throws -> ReviewsRefreshResponse {
    try await post("/v1/reviews/refresh", body: request)
  }

  public func fetchReviewBody(
    request: ReviewsBodyRequest
  ) async throws -> ReviewsBodyResponse {
    try await post("/v1/reviews/body", body: request)
  }

  public func updateReviewBody(
    request: ReviewsBodyUpdateRequest
  ) async throws -> ReviewsBodyUpdateResponse {
    try await post("/v1/reviews/body/update", body: request)
  }

  public func commentReviews(
    request: ReviewsCommentRequest
  ) async throws -> ReviewsActionResponse {
    try await post("/v1/reviews/comment", body: request)
  }

  public func listReviewFiles(
    request: ReviewsFilesListRequest
  ) async throws -> ReviewsFilesListResponse {
    try await post("/v1/reviews/files/list", body: request)
  }

  public func patchReviewFiles(
    request: ReviewsFilesPatchRequest
  ) async throws -> ReviewsFilesPatchResponse {
    try await post("/v1/reviews/files/patch", body: request)
  }

  public func viewedReviewFiles(
    request: ReviewsFilesViewedRequest
  ) async throws -> ReviewsFilesViewedResponse {
    try await post("/v1/reviews/files/viewed", body: request)
  }

  public func fetchReviewFileBlob(
    request: ReviewsFilesBlobRequest
  ) async throws -> ReviewsFilesBlobResponse {
    try await post("/v1/reviews/files/blob", body: request)
  }

  public func listReviewLocalClones() async throws -> [ReviewLocalCloneEntry] {
    let body = ReviewsFilesLocalClonesListRequest()
    return try await post("/v1/reviews/files/local-clones", body: body)
  }

  public func deleteReviewLocalClone(repoKeySegment: String) async throws {
    let body = ReviewsFilesLocalClonesDeleteRequest(repoKeySegment: repoKeySegment)
    let _: ReviewsFilesLocalClonesDeleteResponse = try await post(
      "/v1/reviews/files/local-clones/delete",
      body: body
    )
  }

  public func fetchReviewTimeline(
    request: ReviewsTimelineRequest
  ) async throws -> ReviewsTimelineResponse {
    try await post("/v1/reviews/timeline", body: request)
  }

  public func setReviewThreadResolved(
    request: ReviewsReviewThreadResolveRequest
  ) async throws -> ReviewsReviewThreadResolveResponse {
    try await post("/v1/reviews/review-threads/resolve", body: request)
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

/// Response body for the local clones delete handler. Returns the post-
/// delete listing so the Settings panel can refresh without an extra
/// round-trip.
public struct ReviewsFilesLocalClonesDeleteResponse: Codable, Equatable, Sendable {
  public let clones: [ReviewLocalCloneEntry]

  public init(clones: [ReviewLocalCloneEntry] = []) {
    self.clones = clones
  }
}
