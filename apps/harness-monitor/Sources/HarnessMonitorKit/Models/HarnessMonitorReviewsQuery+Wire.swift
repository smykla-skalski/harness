import Foundation

// Maps the queryReviews response graph - ReviewsQueryResponse and its nested
// ReviewItem / ReviewCheck / PullRequestReview / ReviewRepositoryLabel /
// ReviewsSummary - to the generated wire types in
// Models/Generated/ReviewsTypesWireTypes.generated.swift. This is the
// highest-traffic reviews decode, so it now rides the generated *Wire types on
// the plain PolicyWireCoding decoder instead of convertFromSnakeCase.
//
// The daemon always serializes author_association and the flattened
// viewer_can_update flag (both carry serde defaults but no
// skip_serializing_if), so the wire decode never falls back to a default that
// would diverge from the prior hand init, and there are no legacy daemons that
// omit them. The ReviewsQueryResponse map routes through the memberwise init so
// the item de-duplication in normalizedReviewItems(_:) and the summary
// re-derivation on a changed item count stay intact.

extension ReviewsSummary {
  init(wire: ReviewsSummaryWire) {
    self.init(
      total: Int(wire.total),
      reviewRequired: Int(wire.reviewRequired),
      readyToMerge: Int(wire.readyToMerge),
      autoApprovable: Int(wire.autoApprovable),
      waitingOnChecks: Int(wire.waitingOnChecks),
      blocked: Int(wire.blocked)
    )
  }
}

extension ReviewCheck {
  init(wire: ReviewCheckWire) {
    self.init(
      name: wire.name,
      status: wire.status,
      conclusion: wire.conclusion,
      checkSuiteID: wire.checkSuiteId,
      detailsURL: wire.detailsUrl
    )
  }
}

extension PullRequestReview {
  init(wire: PullRequestReviewWire) {
    self.init(
      author: wire.author,
      authorAvatarURL: wire.authorAvatarUrl.flatMap { URL(string: $0) },
      state: wire.state
    )
  }
}

extension ReviewRepositoryLabel {
  init(wire: ReviewRepositoryLabelWire) {
    self.init(name: wire.name, color: wire.color, description: wire.description)
  }
}

extension ReviewItem {
  init(wire: ReviewItemWire) {
    self.init(
      pullRequestID: wire.pullRequestId,
      repositoryID: wire.repositoryId,
      repository: wire.repository,
      number: wire.number,
      title: wire.title,
      url: wire.url,
      baseRefName: wire.baseRefName,
      defaultBranchName: wire.defaultBranchName,
      backportSource: wire.backportSource,
      authorLogin: wire.authorLogin,
      authorAvatarURL: wire.authorAvatarUrl.flatMap { URL(string: $0) },
      authorAssociation: wire.authorAssociation,
      state: wire.state,
      mergeable: wire.mergeable,
      reviewStatus: wire.reviewStatus,
      checkStatus: wire.checkStatus,
      policyBlocked: wire.policyBlocked,
      isDraft: wire.isDraft,
      headSha: wire.headSha,
      labels: wire.labels,
      checks: wire.checks.map(ReviewCheck.init(wire:)),
      reviews: wire.reviews.map(PullRequestReview.init(wire:)),
      additions: wire.additions,
      deletions: wire.deletions,
      createdAt: wire.createdAt,
      updatedAt: wire.updatedAt,
      requiredFailedCheckNames: wire.requiredFailedCheckNames,
      viewerIsRequestedReviewer: wire.viewerIsRequestedReviewer,
      viewerCanUpdate: wire.viewerCanUpdate,
      viewerCanMergeAsAdmin: wire.viewerCanMergeAsAdmin
    )
  }
}

extension ReviewsQueryResponse {
  init(wire: ReviewsQueryResponseWire) {
    self.init(
      fetchedAt: wire.fetchedAt,
      fromCache: wire.fromCache,
      summary: ReviewsSummary(wire: wire.summary),
      items: wire.items.map(ReviewItem.init(wire:)),
      repositoryLabels: wire.repositoryLabels.mapValues {
        $0.map(ReviewRepositoryLabel.init(wire:))
      },
      viewerLogin: wire.viewerLogin
    )
  }
}

extension ReviewsQueryRequestWire {
  init(_ model: ReviewsQueryRequest) {
    self.init(
      authors: model.authors,
      organizations: model.organizations,
      repositories: model.repositories,
      excludeRepositories: model.excludeRepositories,
      forceRefresh: model.forceRefresh,
      cacheMaxAgeSeconds: model.cacheMaxAgeSeconds,
      backportDetectionEnabled: model.backportDetectionEnabled,
      backportPatterns: model.backportPatterns
    )
  }
}
