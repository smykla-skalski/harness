import Foundation

extension PreviewHarnessClient {
  public func catalogDependencyUpdateRepositories(
    request: DependencyUpdatesRepositoryCatalogRequest
  ) async throws -> DependencyUpdatesRepositoryCatalogResponse {
    try await performActionDelay()
    return await state.catalogDependencyUpdateRepositories(request: request)
  }

  public func queryDependencyUpdates(
    request: DependencyUpdatesQueryRequest
  ) async throws -> DependencyUpdatesQueryResponse {
    try await performActionDelay()
    return await state.currentDependencyUpdates(request: request)
  }

  public func approveDependencyUpdates(
    request: DependencyUpdatesApproveRequest
  ) async throws -> DependencyUpdatesActionResponse {
    try await performActionDelay()
    return await state.approveDependencyUpdates(request: request)
  }

  public func mergeDependencyUpdates(
    request: DependencyUpdatesMergeRequest
  ) async throws -> DependencyUpdatesActionResponse {
    try await performActionDelay()
    return await state.mergeDependencyUpdates(request: request)
  }

  public func rerunDependencyUpdateChecks(
    request: DependencyUpdatesRerunChecksRequest
  ) async throws -> DependencyUpdatesActionResponse {
    try await performActionDelay()
    return await state.rerunDependencyUpdateChecks(request: request)
  }

  public func addDependencyUpdateLabel(
    request: DependencyUpdatesLabelRequest
  ) async throws -> DependencyUpdatesActionResponse {
    try await performActionDelay()
    return await state.addDependencyUpdateLabel(request: request)
  }

  public func autoDependencyUpdates(
    request: DependencyUpdatesAutoRequest
  ) async throws -> DependencyUpdatesActionResponse {
    try await performActionDelay()
    return await state.autoDependencyUpdates(request: request)
  }

  public func clearDependencyUpdatesCache() async throws -> DependencyUpdatesCacheClearResponse {
    try await performActionDelay()
    return await state.clearDependencyUpdatesCache()
  }

  public func refreshDependencyUpdates(
    request: DependencyUpdatesRefreshRequest
  ) async throws -> DependencyUpdatesRefreshResponse {
    try await performActionDelay()
    return await state.refreshDependencyUpdates(request: request)
  }

  public func fetchDependencyUpdateBody(
    request: DependencyUpdatesBodyRequest
  ) async throws -> DependencyUpdatesBodyResponse {
    try await performActionDelay()
    return await state.fetchDependencyUpdateBody(request: request)
  }

  public func updateDependencyUpdateBody(
    request: DependencyUpdatesBodyUpdateRequest
  ) async throws -> DependencyUpdatesBodyUpdateResponse {
    try await performActionDelay()
    return await state.updateDependencyUpdateBody(request: request)
  }

  public func commentDependencyUpdates(
    request: DependencyUpdatesCommentRequest
  ) async throws -> DependencyUpdatesActionResponse {
    try await performActionDelay()
    return await state.commentDependencyUpdates(request: request)
  }
}
