import Foundation

// Maps the reviews action endpoints - approve / merge / rerun-checks / label /
// auto / comment / request-review - to the generated wire types in
// Models/Generated/ReviewsTypesWireTypes.generated.swift. All seven share the
// [ReviewTarget] -> [ReviewTargetWire] request encode and the
// ReviewsActionResponse decode, so they reroute as one cluster onto the plain
// PolicyWireCoding coder.
//
// The hand ReviewTarget.encode(to:) omits fields at their defaults
// (state == .open, viewerCanUpdate, empty arrays); ReviewTargetWire emits the
// full set. The daemon deserializes ReviewTarget with serde defaults, so it
// reconstructs the identical value from either form - the reroute drops the
// convertToSnakeCase dependency (the hand `case checkSuiteIDs = "checkSuiteIds"`
// workaround) without changing what the daemon sees. ReviewActionResult reuses
// the timeline ReviewTimelineEntry(wire:) bridge for its optional entry.

extension ReviewTargetWire {
  init(_ model: ReviewTarget) {
    self.init(
      pullRequestId: model.pullRequestID,
      repositoryId: model.repositoryID,
      repository: model.repository,
      number: model.number,
      url: model.url,
      state: model.state,
      headSha: model.headSha,
      mergeable: model.mergeable,
      reviewStatus: model.reviewStatus,
      checkStatus: model.checkStatus,
      isDraft: model.isDraft,
      policyBlocked: model.policyBlocked,
      viewerCanUpdate: model.viewerCanUpdate,
      viewerCanMergeAsAdmin: model.viewerCanMergeAsAdmin,
      requiredFailedCheckNames: model.requiredFailedCheckNames,
      checkSuiteIds: model.checkSuiteIDs,
      hasConflictMarkers: model.hasConflictMarkers,
      viewerHasActiveApproval: model.viewerHasActiveApproval,
      autoMergeEnabled: model.autoMergeEnabled,
      approvalRequirementSatisfiedAfterViewerApproval:
        model.approvalsSatisfiedAfterViewerApproval
    )
  }
}

extension ReviewsApproveRequestWire {
  init(_ model: ReviewsApproveRequest) {
    self.init(targets: model.targets.map { ReviewTargetWire($0) })
  }
}

extension ReviewsMergeRequestWire {
  init(_ model: ReviewsMergeRequest) {
    self.init(targets: model.targets.map { ReviewTargetWire($0) }, method: model.method)
  }
}

extension ReviewsRerunChecksRequestWire {
  init(_ model: ReviewsRerunChecksRequest) {
    self.init(targets: model.targets.map { ReviewTargetWire($0) })
  }
}

extension ReviewsLabelRequestWire {
  init(_ model: ReviewsLabelRequest) {
    self.init(targets: model.targets.map { ReviewTargetWire($0) }, label: model.label)
  }
}

extension ReviewsAutoRequestWire {
  init(_ model: ReviewsAutoRequest) {
    self.init(targets: model.targets.map { ReviewTargetWire($0) }, method: model.method)
  }
}

extension ReviewsCommentRequestWire {
  init(_ model: ReviewsCommentRequest) {
    self.init(targets: model.targets.map { ReviewTargetWire($0) }, body: model.body)
  }
}

extension ReviewsRequestReviewRequestWire {
  init(_ model: ReviewsRequestReviewRequest) {
    self.init(
      targets: model.targets.map { ReviewTargetWire($0) },
      reviewerLogin: model.reviewerLogin
    )
  }
}

extension ReviewActionResult {
  init(wire: ReviewActionResultWire) {
    self.init(
      repository: wire.repository,
      number: wire.number,
      action: wire.action,
      outcome: wire.outcome,
      message: wire.message,
      timelineEntry: wire.timelineEntry.map(ReviewTimelineEntry.init(wire:))
    )
  }
}

extension ReviewsActionResponse {
  init(wire: ReviewsActionResponseWire) {
    self.init(
      summary: wire.summary,
      results: wire.results.map(ReviewActionResult.init(wire:))
    )
  }
}
