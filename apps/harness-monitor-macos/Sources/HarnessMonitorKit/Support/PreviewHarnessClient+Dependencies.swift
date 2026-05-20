import Foundation

extension PreviewHarnessClient {
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
}
