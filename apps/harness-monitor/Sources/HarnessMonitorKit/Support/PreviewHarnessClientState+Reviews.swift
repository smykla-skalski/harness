import Foundation

private actor PreviewReviewsPolicyRunStore {
  static let shared = PreviewReviewsPolicyRunStore()

  private var runsByStateID: [ObjectIdentifier: [String: [ReviewsPolicyRunResponse]]] = [:]

  func runs(
    for stateID: ObjectIdentifier,
    subjectKey: String
  ) -> [ReviewsPolicyRunResponse] {
    runsByStateID[stateID]?[subjectKey] ?? []
  }

  func save(
    _ runs: [ReviewsPolicyRunResponse],
    for stateID: ObjectIdentifier,
    subjectKey: String
  ) {
    var stateRuns = runsByStateID[stateID] ?? [:]
    stateRuns[subjectKey] = runs
    runsByStateID[stateID] = stateRuns
  }
}

extension PreviewHarnessClientState {
  func previewReviewsPolicy(
    _ request: ReviewsPolicyPreviewRequest
  ) -> ReviewsPolicyPreviewResponse {
    let target = request.target
    if target.state != .open {
      return ReviewsPolicyPreviewResponse(
        eligible: false,
        reason: "Pull request is closed.",
        warnings: []
      )
    }
    if target.isDraft {
      return ReviewsPolicyPreviewResponse(
        eligible: false,
        reason: "Pull request is still a draft.",
        warnings: []
      )
    }
    if target.policyBlocked {
      return ReviewsPolicyPreviewResponse(
        eligible: false,
        reason: "Repository policy is currently blocking automation.",
        warnings: previewReviewsPolicyWarnings(for: target)
      )
    }
    if !target.viewerCanUpdate {
      return ReviewsPolicyPreviewResponse(
        eligible: false,
        reason: "You do not have permission to update this pull request.",
        warnings: []
      )
    }

    var steps: [ReviewsPolicyPreviewStep] = []
    if target.reviewStatus != .approved {
      steps.append(
        ReviewsPolicyPreviewStep(
          stepType: .action,
          actionKey: "reviews.approve"
        )
      )
    }
    if target.checkStatus != .success {
      steps.append(
        ReviewsPolicyPreviewStep(
          stepType: .wait,
          waitingOn: ReviewsPolicyWait(eventKey: "reviews.checks_passed")
        )
      )
    }
    if target.mergeable == .mergeable || target.viewerCanMergeAsAdmin {
      steps.append(
        ReviewsPolicyPreviewStep(
          stepType: .action,
          actionKey: "reviews.merge"
        )
      )
    }

    if steps.isEmpty {
      return ReviewsPolicyPreviewResponse(
        eligible: false,
        reason: "No policy actions are currently applicable.",
        warnings: previewReviewsPolicyWarnings(for: target)
      )
    }

    return ReviewsPolicyPreviewResponse(
      eligible: true,
      steps: steps,
      warnings: previewReviewsPolicyWarnings(for: target)
    )
  }

  func startReviewsPolicyRun(
    _ request: ReviewsPolicyRunStartRequest
  ) async throws -> ReviewsPolicyRunResponse {
    let preview = previewReviewsPolicy(
      ReviewsPolicyPreviewRequest(
        target: request.target,
        method: request.method,
        workflowID: request.workflowID
      )
    )
    guard preview.eligible, !preview.steps.isEmpty else {
      throw HarnessMonitorAPIError.server(
        code: 422,
        message: preview.reason ?? "Reviews policy is not eligible for this pull request."
      )
    }

    let target = request.target
    var recordedSteps: [ReviewsPolicyRunStep] = []
    var waitingOn: ReviewsPolicyWait?
    var status: ReviewsPolicyRunStatus = .completed
    let now = Self.mutationTimestamp

    for step in preview.steps {
      if step.stepType == .action {
        if step.actionKey == "reviews.approve" {
          reviewItems = reviewItems.map { item in
            guard item.pullRequestID == target.pullRequestID else { return item }
            return item.replacing(reviewStatus: .approved)
          }
        } else if step.actionKey == "reviews.merge" {
          reviewItems.removeAll { $0.pullRequestID == target.pullRequestID }
        }
        recordedSteps.append(
          ReviewsPolicyRunStep(
            stepType: .action,
            actionKey: step.actionKey,
            recordedAt: now
          )
        )
      } else if step.stepType == .wait {
        waitingOn = step.waitingOn
        status = .waiting
        recordedSteps.append(
          ReviewsPolicyRunStep(
            stepType: .wait,
            waitingOn: step.waitingOn,
            recordedAt: now
          )
        )
      } else {
        recordedSteps.append(
          ReviewsPolicyRunStep(
            stepType: step.stepType,
            actionKey: step.actionKey,
            waitingOn: step.waitingOn,
            recordedAt: now
          )
        )
      }
      if waitingOn != nil {
        break
      }
    }

    let run = ReviewsPolicyRunResponse(
      runID: previewRunID(for: request),
      workflowID: request.normalizedWorkflowID,
      subject: request.target.reviewsPolicySubject,
      trigger: request.trigger,
      status: status,
      startedAt: now,
      updatedAt: now,
      waitingOn: waitingOn,
      completedAt: status == .completed ? now : nil,
      steps: recordedSteps
    )
    let subjectKey = request.target.reviewsPolicySubject.subjectKey
    let stateID = ObjectIdentifier(self)
    let existingRuns = await PreviewReviewsPolicyRunStore.shared.runs(
      for: stateID,
      subjectKey: subjectKey
    )
    let recentRuns = [run] + existingRuns.filter { $0.runID != run.runID }
    await PreviewReviewsPolicyRunStore.shared.save(
      Array(recentRuns.prefix(10)),
      for: stateID,
      subjectKey: subjectKey
    )
    return run
  }

  func reviewsPolicyStatus(
    _ request: ReviewsPolicyStatusRequest
  ) async throws -> ReviewsPolicyStatusResponse {
    let subjectKey = request.subject.subjectKey
    let stateID = ObjectIdentifier(self)
    var recentRuns = await PreviewReviewsPolicyRunStore.shared.runs(
      for: stateID,
      subjectKey: subjectKey
    )
    if let activeIndex = recentRuns.firstIndex(where: \.status.isActive),
       recentRuns[activeIndex].status == .waiting,
       let item = reviewItems.first(where: {
         $0.repository == request.subject.repository && $0.number == request.subject.pullRequestNumber
       }),
       item.checkStatus == .success,
       item.mergeable == .mergeable || item.viewerCanMergeAsAdmin
    {
      var activeRun = recentRuns[activeIndex]
      let now = Self.mutationTimestamp
      activeRun = ReviewsPolicyRunResponse(
        runID: activeRun.runID,
        workflowID: activeRun.workflowID,
        subject: activeRun.subject,
        trigger: activeRun.trigger,
        status: .completed,
        startedAt: activeRun.startedAt,
        updatedAt: now,
        completedAt: now,
        steps: activeRun.steps + [
          ReviewsPolicyRunStep(
            stepType: .action,
            actionKey: "reviews.merge",
            recordedAt: now
          )
        ]
      )
      recentRuns[activeIndex] = activeRun
      reviewItems.removeAll { $0.pullRequestID == item.pullRequestID }
      await PreviewReviewsPolicyRunStore.shared.save(
        recentRuns,
        for: stateID,
        subjectKey: subjectKey
      )
    }

    let activeRun = recentRuns.first(where: \.status.isActive)
    return ReviewsPolicyStatusResponse(
      activeRun: activeRun,
      recentRuns: recentRuns
    )
  }

  private func previewReviewsPolicyWarnings(for target: ReviewTarget) -> [String] {
    var warnings: [String] = []
    if !target.requiredFailedCheckNames.isEmpty {
      warnings.append(
        "Required checks failing: \(target.requiredFailedCheckNames.joined(separator: ", "))"
      )
    }
    if target.checkStatus != .success {
      warnings.append("Merge will wait for required checks to pass.")
    }
    return warnings
  }

  private func previewRunID(for request: ReviewsPolicyRunStartRequest) -> String {
    let repositoryKey = request.target.repository.replacingOccurrences(of: "/", with: "-")
    return "\(request.normalizedWorkflowID)-\(repositoryKey)-\(request.target.number)"
  }
}

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
    let approveTargets = request.targets.filter(\.isAutoApprovable)
    let mergeTargets = request.targets.filter(\.isAutoMergeable)
    for target in approveTargets {
      reviewItems = reviewItems.map { item in
        guard item.pullRequestID == target.pullRequestID else { return item }
        return item.replacing(reviewStatus: .approved)
      }
    }
    let mergedIDs = Set(mergeTargets.map(\.pullRequestID))
    reviewItems.removeAll { mergedIDs.contains($0.pullRequestID) }
    let results =
      approveTargets.map { target in
        ReviewActionResult(
          repository: target.repository,
          number: target.number,
          action: .autoApprove,
          outcome: .applied
        )
      }
      + mergeTargets.map { target in
        ReviewActionResult(
          repository: target.repository,
          number: target.number,
          action: .autoMerge,
          outcome: .applied
        )
      }
    return ReviewsActionResponse(
      summary: "Auto mode finished: \(results.count) applied, 0 skipped, 0 failed",
      results: results
    )
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
