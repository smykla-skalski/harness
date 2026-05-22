import Foundation

extension HarnessMonitorAPIClient {
  public func catalogDependencyUpdateRepositories(
    request: DependencyUpdatesRepositoryCatalogRequest
  ) async throws -> DependencyUpdatesRepositoryCatalogResponse {
    try await post("/v1/dependency-updates/repositories", body: request)
  }

  public func queryDependencyUpdates(
    request: DependencyUpdatesQueryRequest
  ) async throws -> DependencyUpdatesQueryResponse {
    try await post("/v1/dependency-updates/query", body: request)
  }

  public func dependencyUpdatesCapabilities() async throws -> DependencyUpdatesCapabilitiesResponse
  {
    try await get("/v1/dependency-updates/capabilities")
  }

  public func previewDependencyUpdateAction(
    request: DependencyUpdatesActionPreviewRequest
  ) async throws -> DependencyUpdatesActionPreviewResponse {
    try await post("/v1/dependency-updates/action-preview", body: request)
  }

  public func approveDependencyUpdates(
    request: DependencyUpdatesApproveRequest
  ) async throws -> DependencyUpdatesActionResponse {
    try await post("/v1/dependency-updates/approve", body: request)
  }

  public func mergeDependencyUpdates(
    request: DependencyUpdatesMergeRequest
  ) async throws -> DependencyUpdatesActionResponse {
    try await post("/v1/dependency-updates/merge", body: request)
  }

  public func rerunDependencyUpdateChecks(
    request: DependencyUpdatesRerunChecksRequest
  ) async throws -> DependencyUpdatesActionResponse {
    try await post("/v1/dependency-updates/rerun-checks", body: request)
  }

  public func addDependencyUpdateLabel(
    request: DependencyUpdatesLabelRequest
  ) async throws -> DependencyUpdatesActionResponse {
    try await post("/v1/dependency-updates/labels", body: request)
  }

  public func autoDependencyUpdates(
    request: DependencyUpdatesAutoRequest
  ) async throws -> DependencyUpdatesActionResponse {
    try await post("/v1/dependency-updates/auto", body: request)
  }

  public func clearDependencyUpdatesCache() async throws -> DependencyUpdatesCacheClearResponse {
    try await delete("/v1/dependency-updates/cache")
  }

  public func refreshDependencyUpdates(
    request: DependencyUpdatesRefreshRequest
  ) async throws -> DependencyUpdatesRefreshResponse {
    try await post("/v1/dependency-updates/refresh", body: request)
  }

  public func fetchDependencyUpdateBody(
    request: DependencyUpdatesBodyRequest
  ) async throws -> DependencyUpdatesBodyResponse {
    try await post("/v1/dependency-updates/body", body: request)
  }

  public func updateDependencyUpdateBody(
    request: DependencyUpdatesBodyUpdateRequest
  ) async throws -> DependencyUpdatesBodyUpdateResponse {
    try await post("/v1/dependency-updates/body/update", body: request)
  }

  public func commentDependencyUpdates(
    request: DependencyUpdatesCommentRequest
  ) async throws -> DependencyUpdatesActionResponse {
    try await post("/v1/dependency-updates/comment", body: request)
  }

  public func listDependencyUpdateFiles(
    request: DependencyUpdatesFilesListRequest
  ) async throws -> DependencyUpdatesFilesListResponse {
    try await post("/v1/dependency-updates/files/list", body: request)
  }

  public func patchDependencyUpdateFiles(
    request: DependencyUpdatesFilesPatchRequest
  ) async throws -> DependencyUpdatesFilesPatchResponse {
    try await post("/v1/dependency-updates/files/patch", body: request)
  }

  public func viewedDependencyUpdateFiles(
    request: DependencyUpdatesFilesViewedRequest
  ) async throws -> DependencyUpdatesFilesViewedResponse {
    try await post("/v1/dependency-updates/files/viewed", body: request)
  }

  public func fetchDependencyUpdateFileBlob(
    request: DependencyUpdatesFilesBlobRequest
  ) async throws -> DependencyUpdatesFilesBlobResponse {
    try await post("/v1/dependency-updates/files/blob", body: request)
  }

  public func listDependencyUpdateLocalClones() async throws -> [DependencyUpdateLocalCloneEntry] {
    let body = DependencyUpdatesFilesLocalClonesListRequest()
    return try await post("/v1/dependency-updates/files/local-clones", body: body)
  }

  public func deleteDependencyUpdateLocalClone(repoKeySegment: String) async throws {
    let body = DependencyUpdatesFilesLocalClonesDeleteRequest(repoKeySegment: repoKeySegment)
    let _: DependencyUpdatesFilesLocalClonesDeleteResponse = try await post(
      "/v1/dependency-updates/files/local-clones/delete",
      body: body
    )
  }

  public func fetchDependencyUpdateTimeline(
    request: DependencyUpdatesTimelineRequest
  ) async throws -> DependencyUpdatesTimelineResponse {
    try await post("/v1/dependency-updates/timeline", body: request)
  }
}

/// Empty request body for listing local clones. The daemon does not need
/// any parameters but the HTTP route expects a POST so we send an empty
/// payload to satisfy the contract.
public struct DependencyUpdatesFilesLocalClonesListRequest: Codable, Equatable, Sendable {
  public init() {}
}

/// Request body for deleting a single local clone by repo key segment.
public struct DependencyUpdatesFilesLocalClonesDeleteRequest: Codable, Equatable, Sendable {
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
public struct DependencyUpdatesFilesLocalClonesDeleteResponse: Codable, Equatable, Sendable {
  public let clones: [DependencyUpdateLocalCloneEntry]

  public init(clones: [DependencyUpdateLocalCloneEntry] = []) {
    self.clones = clones
  }
}
