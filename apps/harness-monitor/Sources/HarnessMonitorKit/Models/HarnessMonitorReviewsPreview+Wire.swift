import Foundation

// Maps the remaining non-policy reviews endpoints - capabilities,
// action-preview and refresh - to the generated wire types in
// Models/Generated/ReviewsTypesWireTypes.generated.swift. capabilities is a
// pure response; action-preview and refresh carry [ReviewTarget] requests that
// reuse the ReviewTargetWire(_:) encode from the action cluster, and refresh
// decodes [ReviewItem] through the ReviewItem(wire:) bridge from the query
// cluster. The nested ReviewsCapabilitiesResponse on the preview response and
// the UInt counts (-> Int) are the only shape adjustments.

extension ReviewsCapabilitiesResponse {
  init(wire: ReviewsCapabilitiesResponseWire) {
    self.init(
      schemaVersion: wire.schemaVersion,
      supportsActionPreview: wire.supportsActionPreview,
      supportsCheckRunLinks: wire.supportsCheckRunLinks,
      supportsRepositorySyncHealth: wire.supportsRepositorySyncHealth,
      supportsPersistentActionDiagnostics: wire.supportsPersistentActionDiagnostics
    )
  }
}

extension ReviewActionPreviewTarget {
  init(wire: ReviewActionPreviewTargetWire) {
    self.init(
      pullRequestID: wire.pullRequestId,
      repository: wire.repository,
      number: wire.number,
      eligible: wire.eligible,
      reason: wire.reason,
      warnings: wire.warnings
    )
  }
}

extension ReviewsActionPreviewResponse {
  init(wire: ReviewsActionPreviewResponseWire) {
    self.init(
      action: wire.action,
      capabilities: ReviewsCapabilitiesResponse(wire: wire.capabilities),
      totalCount: Int(wire.totalCount),
      actionableCount: Int(wire.actionableCount),
      skippedCount: Int(wire.skippedCount),
      warnings: wire.warnings,
      targets: wire.targets.map(ReviewActionPreviewTarget.init(wire:))
    )
  }
}

extension ReviewsActionPreviewRequestWire {
  init(_ model: ReviewsActionPreviewRequest) {
    self.init(
      action: model.action,
      targets: model.targets.map { ReviewTargetWire($0) },
      method: model.method
    )
  }
}

extension ReviewsRefreshResponse {
  init(wire: ReviewsRefreshResponseWire) {
    self.init(
      fetchedAt: wire.fetchedAt,
      items: wire.items.map(ReviewItem.init(wire:)),
      missingPullRequestIDs: wire.missingPullRequestIds
    )
  }
}

extension ReviewsRefreshRequestWire {
  init(_ model: ReviewsRefreshRequest) {
    self.init(
      targets: model.targets.map { ReviewTargetWire($0) },
      backportDetectionEnabled: model.backportDetectionEnabled,
      backportPatterns: model.backportPatterns
    )
  }
}
