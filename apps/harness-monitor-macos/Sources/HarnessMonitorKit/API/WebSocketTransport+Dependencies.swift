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

  public func dependencyUpdatesCapabilities() async throws -> DependencyUpdatesCapabilitiesResponse
  {
    let value = try await rpc(method: .dependencyUpdatesCapabilities, params: nil)
    return try decode(value)
  }

  public func previewDependencyUpdateAction(
    request: DependencyUpdatesActionPreviewRequest
  ) async throws -> DependencyUpdatesActionPreviewResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesActionPreview, params: params)
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

  public func commentDependencyUpdates(
    request: DependencyUpdatesCommentRequest
  ) async throws -> DependencyUpdatesActionResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesComment, params: params)
    return try decode(value)
  }

  public func listDependencyUpdateFiles(
    request: DependencyUpdatesFilesListRequest
  ) async throws -> DependencyUpdatesFilesListResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesFilesList, params: params)
    return try decode(value)
  }

  public func patchDependencyUpdateFiles(
    request: DependencyUpdatesFilesPatchRequest
  ) async throws -> DependencyUpdatesFilesPatchResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesFilesPatch, params: params)
    return try decode(value)
  }

  public func viewedDependencyUpdateFiles(
    request: DependencyUpdatesFilesViewedRequest
  ) async throws -> DependencyUpdatesFilesViewedResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesFilesViewed, params: params)
    return try decode(value)
  }

  public func fetchDependencyUpdateFileBlob(
    request: DependencyUpdatesFilesBlobRequest
  ) async throws -> DependencyUpdatesFilesBlobResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .dependencyUpdatesFilesBlob, params: params)
    return try decode(value)
  }

  public func listDependencyUpdateLocalClones() async throws -> [DependencyUpdateLocalCloneEntry] {
    let value = try await rpc(method: .dependencyUpdatesFilesLocalClonesList, params: nil)
    return try decode(value)
  }

  public func deleteDependencyUpdateLocalClone(repoKeySegment: String) async throws {
    let request = DependencyUpdatesFilesLocalClonesDeleteRequest(repoKeySegment: repoKeySegment)
    let params = try encodeParams(request, extra: [:])
    _ = try await rpc(method: .dependencyUpdatesFilesLocalClonesDelete, params: params)
  }
}
