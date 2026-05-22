import Foundation

public protocol HarnessMonitorDependenciesClientProtocol: Sendable {
  func catalogDependencyUpdateRepositories(
    request: DependencyUpdatesRepositoryCatalogRequest
  ) async throws -> DependencyUpdatesRepositoryCatalogResponse
  func dependencyUpdatesCapabilities() async throws -> DependencyUpdatesCapabilitiesResponse
  func queryDependencyUpdates(
    request: DependencyUpdatesQueryRequest
  ) async throws -> DependencyUpdatesQueryResponse
  func previewDependencyUpdateAction(
    request: DependencyUpdatesActionPreviewRequest
  ) async throws -> DependencyUpdatesActionPreviewResponse
  func approveDependencyUpdates(
    request: DependencyUpdatesApproveRequest
  ) async throws -> DependencyUpdatesActionResponse
  func mergeDependencyUpdates(
    request: DependencyUpdatesMergeRequest
  ) async throws -> DependencyUpdatesActionResponse
  func rerunDependencyUpdateChecks(
    request: DependencyUpdatesRerunChecksRequest
  ) async throws -> DependencyUpdatesActionResponse
  func addDependencyUpdateLabel(
    request: DependencyUpdatesLabelRequest
  ) async throws -> DependencyUpdatesActionResponse
  func autoDependencyUpdates(
    request: DependencyUpdatesAutoRequest
  ) async throws -> DependencyUpdatesActionResponse
  func clearDependencyUpdatesCache() async throws -> DependencyUpdatesCacheClearResponse
  func refreshDependencyUpdates(
    request: DependencyUpdatesRefreshRequest
  ) async throws -> DependencyUpdatesRefreshResponse
  func fetchDependencyUpdateBody(
    request: DependencyUpdatesBodyRequest
  ) async throws -> DependencyUpdatesBodyResponse
  func updateDependencyUpdateBody(
    request: DependencyUpdatesBodyUpdateRequest
  ) async throws -> DependencyUpdatesBodyUpdateResponse
  func commentDependencyUpdates(
    request: DependencyUpdatesCommentRequest
  ) async throws -> DependencyUpdatesActionResponse
  func listDependencyUpdateFiles(
    request: DependencyUpdatesFilesListRequest
  ) async throws -> DependencyUpdatesFilesListResponse
  func patchDependencyUpdateFiles(
    request: DependencyUpdatesFilesPatchRequest
  ) async throws -> DependencyUpdatesFilesPatchResponse
  func viewedDependencyUpdateFiles(
    request: DependencyUpdatesFilesViewedRequest
  ) async throws -> DependencyUpdatesFilesViewedResponse
  func fetchDependencyUpdateFileBlob(
    request: DependencyUpdatesFilesBlobRequest
  ) async throws -> DependencyUpdatesFilesBlobResponse
  func listDependencyUpdateLocalClones() async throws -> [DependencyUpdateLocalCloneEntry]
  func deleteDependencyUpdateLocalClone(
    repoKeySegment: String
  ) async throws
  func fetchDependencyUpdateTimeline(
    request: DependencyUpdatesTimelineRequest
  ) async throws -> DependencyUpdatesTimelineResponse
  func setReviewThreadResolved(
    request: DependencyUpdatesReviewThreadResolveRequest
  ) async throws -> DependencyUpdatesReviewThreadResolveResponse
}

extension HarnessMonitorDependenciesClientProtocol {
  public func catalogDependencyUpdateRepositories(
    request _: DependencyUpdatesRepositoryCatalogRequest
  ) async throws -> DependencyUpdatesRepositoryCatalogResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func queryDependencyUpdates(
    request _: DependencyUpdatesQueryRequest
  ) async throws -> DependencyUpdatesQueryResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func dependencyUpdatesCapabilities()
    async throws -> DependencyUpdatesCapabilitiesResponse
  {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func previewDependencyUpdateAction(
    request _: DependencyUpdatesActionPreviewRequest
  ) async throws -> DependencyUpdatesActionPreviewResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func approveDependencyUpdates(
    request _: DependencyUpdatesApproveRequest
  ) async throws -> DependencyUpdatesActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func mergeDependencyUpdates(
    request _: DependencyUpdatesMergeRequest
  ) async throws -> DependencyUpdatesActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func rerunDependencyUpdateChecks(
    request _: DependencyUpdatesRerunChecksRequest
  ) async throws -> DependencyUpdatesActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func addDependencyUpdateLabel(
    request _: DependencyUpdatesLabelRequest
  ) async throws -> DependencyUpdatesActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func autoDependencyUpdates(
    request _: DependencyUpdatesAutoRequest
  ) async throws -> DependencyUpdatesActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func clearDependencyUpdatesCache() async throws -> DependencyUpdatesCacheClearResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func refreshDependencyUpdates(
    request _: DependencyUpdatesRefreshRequest
  ) async throws -> DependencyUpdatesRefreshResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func fetchDependencyUpdateBody(
    request _: DependencyUpdatesBodyRequest
  ) async throws -> DependencyUpdatesBodyResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func updateDependencyUpdateBody(
    request _: DependencyUpdatesBodyUpdateRequest
  ) async throws -> DependencyUpdatesBodyUpdateResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func commentDependencyUpdates(
    request _: DependencyUpdatesCommentRequest
  ) async throws -> DependencyUpdatesActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func listDependencyUpdateFiles(
    request _: DependencyUpdatesFilesListRequest
  ) async throws -> DependencyUpdatesFilesListResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func patchDependencyUpdateFiles(
    request _: DependencyUpdatesFilesPatchRequest
  ) async throws -> DependencyUpdatesFilesPatchResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func viewedDependencyUpdateFiles(
    request _: DependencyUpdatesFilesViewedRequest
  ) async throws -> DependencyUpdatesFilesViewedResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func fetchDependencyUpdateFileBlob(
    request _: DependencyUpdatesFilesBlobRequest
  ) async throws -> DependencyUpdatesFilesBlobResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func listDependencyUpdateLocalClones() async throws -> [DependencyUpdateLocalCloneEntry] {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func deleteDependencyUpdateLocalClone(repoKeySegment _: String) async throws {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func fetchDependencyUpdateTimeline(
    request _: DependencyUpdatesTimelineRequest
  ) async throws -> DependencyUpdatesTimelineResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func setReviewThreadResolved(
    request _: DependencyUpdatesReviewThreadResolveRequest
  ) async throws -> DependencyUpdatesReviewThreadResolveResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }
}
