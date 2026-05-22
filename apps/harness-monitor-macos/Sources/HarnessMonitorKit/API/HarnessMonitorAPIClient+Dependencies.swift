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
}
