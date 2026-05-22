import Foundation

extension WebSocketTransport {
  public func catalogDependencyUpdateRepositories(
    request: DependencyUpdatesRepositoryCatalogRequest
  ) async throws -> DependencyUpdatesRepositoryCatalogResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesRepositoryCatalog, params: params)
    return try decode(value)
  }

  public func queryDependencyUpdates(
    request: DependencyUpdatesQueryRequest
  ) async throws -> DependencyUpdatesQueryResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesQuery, params: params)
    return try decode(value)
  }

  public func approveDependencyUpdates(
    request: DependencyUpdatesApproveRequest
  ) async throws -> DependencyUpdatesActionResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesApprove, params: params)
    return try decode(value)
  }

  public func mergeDependencyUpdates(
    request: DependencyUpdatesMergeRequest
  ) async throws -> DependencyUpdatesActionResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesMerge, params: params)
    return try decode(value)
  }

  public func rerunDependencyUpdateChecks(
    request: DependencyUpdatesRerunChecksRequest
  ) async throws -> DependencyUpdatesActionResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesRerunChecks, params: params)
    return try decode(value)
  }

  public func addDependencyUpdateLabel(
    request: DependencyUpdatesLabelRequest
  ) async throws -> DependencyUpdatesActionResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesAddLabel, params: params)
    return try decode(value)
  }

  public func autoDependencyUpdates(
    request: DependencyUpdatesAutoRequest
  ) async throws -> DependencyUpdatesActionResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesAuto, params: params)
    return try decode(value)
  }

  public func clearDependencyUpdatesCache() async throws -> DependencyUpdatesCacheClearResponse {
    let value = try await rpc(method: .dependencyUpdatesClearCache, params: nil)
    return try decode(value)
  }

  public func refreshDependencyUpdates(
    request: DependencyUpdatesRefreshRequest
  ) async throws -> DependencyUpdatesRefreshResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesRefresh, params: params)
    return try decode(value)
  }

  public func fetchDependencyUpdateBody(
    request: DependencyUpdatesBodyRequest
  ) async throws -> DependencyUpdatesBodyResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesBody, params: params)
    return try decode(value)
  }

  public func updateDependencyUpdateBody(
    request: DependencyUpdatesBodyUpdateRequest
  ) async throws -> DependencyUpdatesBodyUpdateResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesBodyUpdate, params: params)
    return try decode(value)
  }
}
