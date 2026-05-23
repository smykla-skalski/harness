import Foundation

extension PreviewHarnessClientState {
  func catalogReviewRepositories(
    request: ReviewsRepositoryCatalogRequest
  ) -> ReviewsRepositoryCatalogResponse {
    let organization = request.organization.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let knownRepositories =
      reviewItems.map(\.repository)
      + taskBoardOrchestratorSettings.githubInbox.repositories
    let repositories = Array(
      Set(
        knownRepositories.filter { repository in
          repository.split(separator: "/", maxSplits: 1).first?.lowercased() == organization
        }
      )
    ).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    return ReviewsRepositoryCatalogResponse(
      organization: organization,
      repositories: repositories
    )
  }

  func currentReviews(
    request: ReviewsQueryRequest
  ) -> ReviewsQueryResponse {
    let items = reviewItems.filter { item in
      let owner = item.repository.split(separator: "/").first.map(String.init)
      let matchesOrganizations =
        request.organizations.isEmpty
        || owner.map { request.organizations.contains($0) } == true
      let matchesRepositories =
        request.repositories.isEmpty
        || request.repositories.contains(item.repository)
      let matchesExclusions = !request.excludeRepositories.contains(item.repository)
      let matchesAuthors = request.authors.isEmpty || request.authors.contains(item.authorLogin)
      return matchesOrganizations && matchesRepositories && matchesExclusions && matchesAuthors
    }
    return ReviewsQueryResponse(
      fetchedAt: Self.mutationTimestamp,
      fromCache: false,
      summary: ReviewsSummary(items: items),
      items: items
    )
  }

  func previewReviewAction(
    request: ReviewsActionPreviewRequest
  ) -> ReviewsActionPreviewResponse {
    let targets = request.targets.map { target in
      previewReviewActionTarget(action: request.action, target: target)
    }
    let actionableCount = targets.count(where: \.eligible)
    return ReviewsActionPreviewResponse(
      action: request.action,
      capabilities: ReviewsCapabilitiesResponse(),
      totalCount: request.targets.count,
      actionableCount: actionableCount,
      skippedCount: request.targets.count - actionableCount,
      warnings: previewReviewWarnings(action: request.action, targets: request.targets),
      targets: targets
    )
  }

  func approveReviews(
    request: ReviewsApproveRequest
  ) -> ReviewsActionResponse {
    for target in request.targets {
      reviewItems = reviewItems.map { item in
        guard item.pullRequestID == target.pullRequestID else { return item }
        return item.replacing(reviewStatus: .approved)
      }
    }
    return previewActionResponse(
      summary: "Approved reviews",
      action: .approve,
      request.targets
    )
  }

  func mergeReviews(
    request: ReviewsMergeRequest
  ) -> ReviewsActionResponse {
    let mergedIDs = Set(request.targets.map(\.pullRequestID))
    reviewItems.removeAll { mergedIDs.contains($0.pullRequestID) }
    return previewActionResponse(
      summary: "Merged reviews",
      action: .merge,
      request.targets
    )
  }

  func rerunReviewChecks(
    request: ReviewsRerunChecksRequest
  ) -> ReviewsActionResponse {
    for target in request.targets {
      reviewItems = reviewItems.map { item in
        guard item.pullRequestID == target.pullRequestID else { return item }
        let rerunChecks = item.checks.map { check in
          guard target.checkSuiteIDs.contains(check.checkSuiteID ?? "") else { return check }
          return ReviewCheck(
            name: check.name,
            status: .inProgress,
            conclusion: .none,
            checkSuiteID: check.checkSuiteID,
            detailsURL: check.detailsURL
          )
        }
        return item.replacing(checkStatus: .pending, checks: rerunChecks)
      }
    }
    return previewActionResponse(
      summary: "Reran review checks",
      action: .rerunChecks,
      request.targets
    )
  }

  func addReviewLabel(
    request: ReviewsLabelRequest
  ) -> ReviewsActionResponse {
    for target in request.targets {
      reviewItems = reviewItems.map { item in
        guard item.pullRequestID == target.pullRequestID else { return item }
        var labels = item.labels
        if !labels.contains(request.label) {
          labels.append(request.label)
          labels.sort()
        }
        return item.replacing(labels: labels)
      }
    }
    return previewActionResponse(
      summary: "Labeled reviews",
      action: .addLabel,
      request.targets
    )
  }

  func autoReviews(
    request: ReviewsAutoRequest
  ) -> ReviewsActionResponse {
    for target in request.targets where target.isAutoApprovable {
      reviewItems = reviewItems.map { item in
        guard item.pullRequestID == target.pullRequestID else { return item }
        return item.replacing(reviewStatus: .approved)
      }
    }
    let mergedIDs = Set(request.targets.filter { $0.isAutoMergeable }.map(\.pullRequestID))
    let newlyApprovedIDs = Set(request.targets.filter { $0.isAutoApprovable }.map(\.pullRequestID))
    reviewItems.removeAll {
      mergedIDs.contains($0.pullRequestID) || newlyApprovedIDs.contains($0.pullRequestID)
    }
    return previewActionResponse(summary: "Auto mode finished", action: .autoMerge, request.targets)
  }

  func clearReviewsCache() -> ReviewsCacheClearResponse {
    ReviewsCacheClearResponse(clearedEntries: 1)
  }

  func refreshReviews(
    request: ReviewsRefreshRequest
  ) -> ReviewsRefreshResponse {
    let requestedIDs = Set(request.targets.map(\.pullRequestID))
    let refreshed = reviewItems.filter { requestedIDs.contains($0.pullRequestID) }
    let missing = requestedIDs.subtracting(refreshed.map(\.pullRequestID))
    return ReviewsRefreshResponse(
      fetchedAt: Self.mutationTimestamp,
      items: refreshed,
      missingPullRequestIDs: missing.sorted()
    )
  }

  func fetchReviewBody(
    request: ReviewsBodyRequest
  ) -> ReviewsBodyResponse {
    let item = reviewItems.first { $0.pullRequestID == request.pullRequestID }
    let body =
      item.map {
        """
        Bumps `\($0.repository.split(separator: "/").last ?? "package")` from an older release.

        - Release notes: link
        - Changelog: link

        Closes a tracking issue and keeps dependencies current.
        """
      } ?? ""
    return ReviewsBodyResponse(
      pullRequestID: request.pullRequestID,
      body: body,
      prUpdatedAt: item?.updatedAt ?? "2026-05-21T00:00:00Z",
      fetchedAt: "2026-05-21T00:00:00Z",
      fromCache: false
    )
  }

  func updateReviewBody(
    request: ReviewsBodyUpdateRequest
  ) -> ReviewsBodyUpdateResponse {
    ReviewsBodyUpdateResponse(
      pullRequestID: request.pullRequestID,
      outcome: .updated,
      currentBody: request.newBody,
      currentBodySHA256: request.expectedPriorBodySHA256,
      prUpdatedAt: "2026-05-21T00:00:00Z",
      fetchedAt: "2026-05-21T00:00:00Z"
    )
  }

  func commentReviews(
    request: ReviewsCommentRequest
  ) -> ReviewsActionResponse {
    previewActionResponse(
      summary: "Posted review comment",
      action: .comment,
      request.targets
    )
  }

  func addReviewFileComment(
    request: ReviewsFileCommentRequest
  ) -> ReviewsFileCommentResponse {
    ReviewsFileCommentResponse(
      pullRequestId: request.pullRequestId,
      threadId: request.threadId ?? "preview-thread",
      commentId: "preview-comment",
      url: nil,
      fetchedAt: Self.mutationTimestamp
    )
  }

  func listReviewFiles(
    request: ReviewsFilesListRequest
  ) -> ReviewsFilesListResponse {
    ReviewsFilesListResponse(
      pullRequestID: request.pullRequestID,
      headRefOid: "preview-head-\(request.pullRequestID)",
      viewerCanMarkViewed: true,
      files: [],
      fetchedAt: Self.mutationTimestamp,
      paginationComplete: true
    )
  }

  func patchReviewFiles(
    request: ReviewsFilesPatchRequest
  ) -> ReviewsFilesPatchResponse {
    ReviewsFilesPatchResponse(
      pullRequestID: request.pullRequestID,
      patches: [],
      drifted: false,
      currentHeadRefOid: request.headRefOidExpected,
      fetchedAt: Self.mutationTimestamp
    )
  }

  func previewReviewFiles(
    request: ReviewsFilesPreviewRequest
  ) -> ReviewsFilesPreviewResponse {
    ReviewsFilesPreviewResponse(
      pullRequestID: request.pullRequestID,
      previews: [],
      drifted: false,
      currentHeadRefOid: request.headRefOidExpected,
      fetchedAt: Self.mutationTimestamp
    )
  }

  func viewedReviewFiles(
    request: ReviewsFilesViewedRequest
  ) -> ReviewsFilesViewedResponse {
    ReviewsFilesViewedResponse(
      pullRequestID: request.pullRequestID,
      results: request.paths.map { target in
        ReviewFilesViewedResult(
          path: target.path,
          outcome: .updated,
          viewerViewedState: target.markViewed ? .viewed : .unviewed
        )
      },
      fetchedAt: Self.mutationTimestamp
    )
  }

  func fetchReviewFileBlob(
    request: ReviewsFilesBlobRequest
  ) -> ReviewsFilesBlobResponse {
    ReviewsFilesBlobResponse(
      path: request.path,
      oid: request.oid,
      mime: .png,
      contentBase64: "",
      byteSize: 0,
      fetchedAt: Self.mutationTimestamp
    )
  }

  func listReviewLocalClones() -> [ReviewLocalCloneEntry] {
    []
  }

  func deleteReviewLocalClone(repoKeySegment _: String) {}

  private func previewActionResponse(
    summary: String,
    action: ReviewActionKind,
    _ targets: [ReviewTarget]
  ) -> ReviewsActionResponse {
    ReviewsActionResponse(
      summary: "\(summary): \(targets.count) applied, 0 skipped, 0 failed",
      results: targets.map { target in
        ReviewActionResult(
          repository: target.repository,
          number: target.number,
          action: action,
          outcome: .applied
        )
      }
    )
  }

  private func previewReviewActionTarget(
    action: ReviewActionPreviewKind,
    target: ReviewTarget
  ) -> ReviewActionPreviewTarget {
    let reason = previewReviewBlocker(action: action, target: target)
    return ReviewActionPreviewTarget(
      pullRequestID: target.pullRequestID,
      repository: target.repository,
      number: target.number,
      eligible: reason == nil,
      reason: reason,
      warnings: previewReviewTargetWarnings(action: action, target: target)
    )
  }

  private func previewReviewBlocker(
    action: ReviewActionPreviewKind,
    target: ReviewTarget
  ) -> String? {
    guard target.viewerCanUpdate else {
      return "Current GitHub token cannot update this pull request"
    }
    guard target.state == .open else {
      return "Pull request is not open"
    }
    switch action {
    case .approve:
      return target.reviewStatus == .reviewRequired || target.reviewStatus == .none
        ? nil
        : "Pull request does not need manual approval"
    case .merge:
      if target.isDraft { return "Draft pull requests cannot be merged" }
      return target.mergeable == .conflicting
        ? "Merge conflicts must be resolved before merging"
        : nil
    case .rerunChecks:
      return target.checkSuiteIDs.isEmpty
        ? "No rerunnable check suites were reported"
        : nil
    case .addLabel:
      return nil
    case .auto:
      return target.isAutoApprovable || target.isAutoMergeable
        ? nil
        : "Pull request is not eligible for auto mode"
    case .unknown:
      return "Unknown review action"
    }
  }

  private func previewReviewWarnings(
    action: ReviewActionPreviewKind,
    targets: [ReviewTarget]
  ) -> [String] {
    var warnings: [String] = []
    if action == .approve || action == .merge {
      let failing = targets.count { $0.checkStatus == .failure }
      if failing > 0 {
        warnings.append(
          failing == 1
            ? "1 pull request has failing checks"
            : "\(failing) pull requests have failing checks"
        )
      }
    }
    let policyBlocked = targets.count(where: \.policyBlocked)
    if policyBlocked > 0 {
      warnings.append(
        policyBlocked == 1
          ? "1 pull request is policy-blocked"
          : "\(policyBlocked) pull requests are policy-blocked"
      )
    }
    return warnings
  }

  private func previewReviewTargetWarnings(
    action: ReviewActionPreviewKind,
    target: ReviewTarget
  ) -> [String] {
    var warnings: [String] = []
    if (action == .approve || action == .merge) && target.checkStatus == .failure {
      warnings.append("Checks are failing")
    }
    if target.reviewStatus == .changesRequested {
      warnings.append("A reviewer requested changes")
    }
    if target.policyBlocked {
      warnings.append("Review policy is blocking this pull request")
    }
    return warnings
  }
}
