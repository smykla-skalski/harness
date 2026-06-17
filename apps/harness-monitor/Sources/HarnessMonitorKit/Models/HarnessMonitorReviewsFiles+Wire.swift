import Foundation

// Maps the hand reviews file-list models to the generated wire types in
// Models/Generated/ReviewsFilesWireTypes.generated.swift. The hand models are
// thin mirrors (field-identical, no acronym divergence beyond pullRequestID),
// so the *Wire types own the daemon snake_case shape with explicit CodingKeys
// and the file-list decode runs through them on the plain decoder. The
// change-type and viewed-state wire enums carry the same rawValues as the hand
// enums; languageHint is already the hand HarnessReviewFileLanguage in both.
// The reroute of patch/preview/viewed/blob is a follow-up reusing ReviewFile.

extension ReviewFile {
  init(wire: ReviewFileWire) {
    self.init(
      path: wire.path,
      previousPath: wire.previousPath,
      changeType: ReviewFileChangeType(rawValue: wire.changeType.rawValue) ?? .other,
      additions: wire.additions,
      deletions: wire.deletions,
      viewerViewedState: ReviewFileViewedState(rawValue: wire.viewerViewedState.rawValue)
        ?? .unviewed,
      isBinary: wire.isBinary,
      languageHint: wire.languageHint,
      modeChange: wire.modeChange
    )
  }
}

extension ReviewsRateLimitSnapshot {
  init(wire: ReviewsRateLimitSnapshotWire) {
    self.init(remaining: wire.remaining, limit: wire.limit, resetAt: wire.resetAt, cost: wire.cost)
  }
}

extension ReviewsFilesListResponse {
  init(wire: ReviewsFilesListResponseWire) {
    self.init(
      pullRequestID: wire.pullRequestId,
      number: wire.number,
      headRefOid: wire.headRefOid,
      headRefName: wire.headRefName,
      baseRefOid: wire.baseRefOid,
      baseRefName: wire.baseRefName,
      repositoryFullName: wire.repositoryFullName,
      viewerCanMarkViewed: wire.viewerCanMarkViewed,
      files: wire.files.map(ReviewFile.init(wire:)),
      fetchedAt: wire.fetchedAt,
      paginationComplete: wire.paginationComplete,
      rateLimitSnapshot: wire.rateLimitSnapshot.map(ReviewsRateLimitSnapshot.init(wire:))
    )
  }
}

extension ReviewsFilesListRequestWire {
  init(_ model: ReviewsFilesListRequest) {
    self.init(pullRequestId: model.pullRequestID, forceRefresh: model.forceRefresh)
  }
}

extension ReviewFilePatch {
  init(wire: ReviewFilePatchWire) {
    self.init(
      path: wire.path,
      patch: wire.patch,
      status: ReviewFileChangeType(rawValue: wire.status.rawValue) ?? .other,
      additions: wire.additions,
      deletions: wire.deletions,
      truncated: wire.truncated,
      etag: wire.etag,
      servedBy: ReviewFileServedBy(rawValue: wire.servedBy.rawValue) ?? .githubRest,
      fetchedAt: wire.fetchedAt,
      headRefOid: wire.headRefOid
    )
  }
}

extension ReviewsFilesPatchResponse {
  init(wire: ReviewsFilesPatchResponseWire) {
    self.init(
      pullRequestID: wire.pullRequestId,
      patches: wire.patches.map(ReviewFilePatch.init(wire:)),
      drifted: wire.drifted,
      currentHeadRefOid: wire.currentHeadRefOid,
      fetchedAt: wire.fetchedAt,
      rateLimitSnapshot: wire.rateLimitSnapshot.map(ReviewsRateLimitSnapshot.init(wire:))
    )
  }
}

extension ReviewsFilesPatchRequestWire {
  init(_ model: ReviewsFilesPatchRequest) {
    self.init(
      pullRequestId: model.pullRequestID,
      headRefOidExpected: model.headRefOidExpected,
      paths: model.paths,
      number: model.number,
      repositoryFullName: model.repositoryFullName,
      baseRefOidExpected: model.baseRefOidExpected,
      headRefName: model.headRefName,
      baseRefName: model.baseRefName,
      largeDiffStrategy: model.largeDiffStrategy
        .map { FilesLargeDiffStrategyWire(rawValue: $0.rawValue) ?? .autoLocalClone }
    )
  }
}
