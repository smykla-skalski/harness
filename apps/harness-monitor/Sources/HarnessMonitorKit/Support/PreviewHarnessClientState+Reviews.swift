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
        $0.repository == request.subject.repository
          && $0.number == request.subject.pullRequestNumber
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
