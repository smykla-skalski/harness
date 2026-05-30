import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension DashboardReviewsRouteViewTests {
  @Test("single-PR auto feedback explains approval-only outcomes")
  func singlePRAutoFeedbackExplainsApprovalOnlyOutcomes() {
    let item = reviewItem(reviewStatus: .reviewRequired)
    let response = ReviewsActionResponse(
      summary: "Auto mode finished: 1 applied, 0 skipped, 0 failed",
      results: [
        ReviewActionResult(
          repository: item.repository,
          number: item.number,
          action: .autoApprove,
          outcome: .applied
        )
      ]
    )

    let feedback = dashboardReviewsActionFeedback(
      title: "Auto",
      items: [item],
      response: response
    )

    #expect(feedback.severity == .success)
    #expect(
      feedback.message
        == "Approved org-a/example#42. GitHub still requires review before merge."
    )
  }

  @Test("single-PR auto feedback surfaces merge failures as failures")
  func singlePRAutoFeedbackSurfacesMergeFailures() {
    let item = reviewItem(reviewStatus: .reviewRequired)
    let response = ReviewsActionResponse(
      summary: "Auto mode finished: 1 applied, 0 skipped, 1 failed",
      results: [
        ReviewActionResult(
          repository: item.repository,
          number: item.number,
          action: .autoApprove,
          outcome: .applied
        ),
        ReviewActionResult(
          repository: item.repository,
          number: item.number,
          action: .autoMerge,
          outcome: .failed,
          message: "GitHub still requires review before merge."
        ),
      ]
    )

    let feedback = dashboardReviewsActionFeedback(
      title: "Auto",
      items: [item],
      response: response
    )

    #expect(feedback.severity == .failure)
    #expect(
      feedback.message
        == "Approved org-a/example#42, but merge failed: GitHub still requires review before merge"
    )
  }

  @Test("single-PR auto policy feedback explains waiting runs")
  func singlePRAutoPolicyFeedbackExplainsWaitingRuns() {
    let item = reviewItem(reviewStatus: .reviewRequired, checkStatus: .pending)
    let outcome = DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: ReviewsPolicyPreviewResponse(
        eligible: true,
        steps: [
          ReviewsPolicyPreviewStep(stepType: .action, actionKey: "reviews.approve"),
          ReviewsPolicyPreviewStep(
            stepType: .wait,
            waitingOn: ReviewsPolicyWait(eventKey: "reviews.checks_passed")
          ),
        ]
      ),
      run: ReviewsPolicyRunResponse(
        runID: "run-1",
        subject: item.target.reviewsPolicySubject,
        trigger: .manual,
        status: .waiting,
        startedAt: "2026-05-29T12:00:00Z",
        updatedAt: "2026-05-29T12:00:01Z",
        waitingOn: ReviewsPolicyWait(eventKey: "reviews.checks_passed"),
        steps: [
          ReviewsPolicyRunStep(
            stepType: .action,
            actionKey: "reviews.approve",
            recordedAt: "2026-05-29T12:00:00Z"
          ),
          ReviewsPolicyRunStep(
            stepType: .wait,
            waitingOn: ReviewsPolicyWait(eventKey: "reviews.checks_passed"),
            recordedAt: "2026-05-29T12:00:01Z"
          ),
        ]
      ),
      status: nil,
      skippedReason: nil,
      errorMessage: nil
    )

    let feedback = dashboardReviewsAutoPolicyFeedback(items: [item], outcomes: [outcome])

    #expect(feedback.severity == .warning)
    #expect(
      feedback.message
        == "Auto policy started for org-a/example#42: approved; waiting for required checks to pass."
    )
  }

  @Test("single-PR auto policy feedback explains completed runs")
  func singlePRAutoPolicyFeedbackExplainsCompletedRuns() {
    let item = reviewItem(reviewStatus: .reviewRequired)
    let outcome = DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: ReviewsPolicyPreviewResponse(
        eligible: true,
        steps: [
          ReviewsPolicyPreviewStep(stepType: .action, actionKey: "reviews.approve"),
          ReviewsPolicyPreviewStep(stepType: .action, actionKey: "reviews.merge"),
        ]
      ),
      run: ReviewsPolicyRunResponse(
        runID: "run-1",
        subject: item.target.reviewsPolicySubject,
        trigger: .manual,
        status: .completed,
        startedAt: "2026-05-29T12:00:00Z",
        updatedAt: "2026-05-29T12:00:03Z",
        completedAt: "2026-05-29T12:00:03Z",
        steps: [
          ReviewsPolicyRunStep(
            stepType: .action,
            actionKey: "reviews.approve",
            recordedAt: "2026-05-29T12:00:00Z"
          ),
          ReviewsPolicyRunStep(
            stepType: .action,
            actionKey: "reviews.merge",
            recordedAt: "2026-05-29T12:00:03Z"
          ),
        ]
      ),
      status: nil,
      skippedReason: nil,
      errorMessage: nil
    )

    let feedback = dashboardReviewsAutoPolicyFeedback(items: [item], outcomes: [outcome])

    #expect(feedback.severity == .success)
    #expect(
      feedback.message
        == "Auto policy completed for org-a/example#42: approved and merged."
    )
  }

  @Test("multi-PR auto policy aggregation never reports green when a run is unfinished")
  func multiPRAutoPolicyAggregationNeverReportsGreenForUnfinishedRuns() {
    let item = reviewItem(reviewStatus: .reviewRequired)
    let outcomes = [
      autoPolicyOutcome(item: item, runID: "run-1", status: .completed),
      autoPolicyOutcome(item: item, runID: "run-2", status: .waiting),
      autoPolicyOutcome(
        item: item,
        runID: "run-3",
        status: .failed,
        errorMessage: "merge blocked by branch protection"
      ),
      autoPolicyOutcome(item: item, runID: "run-4", status: .unknown("event")),
    ]

    let feedback = dashboardReviewsAutoPolicyFeedback(
      items: [item, item, item, item],
      outcomes: outcomes
    )

    #expect(feedback.severity != .success)
    #expect(feedback.severity == .failure)
    #expect(feedback.message.contains("1 completed"))
    #expect(feedback.message.contains("1 waiting"))
    #expect(feedback.message.contains("2 failed"))
    #expect(feedback.message.contains("merge blocked by branch protection"))
  }

  private func autoPolicyOutcome(
    item: ReviewItem,
    runID: String,
    status: ReviewsPolicyRunStatus,
    errorMessage: String? = nil
  ) -> DashboardReviewsAutoPolicyOutcome {
    DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: ReviewsPolicyPreviewResponse(
        eligible: true,
        steps: [ReviewsPolicyPreviewStep(stepType: .action, actionKey: "reviews.approve")]
      ),
      run: ReviewsPolicyRunResponse(
        runID: runID,
        subject: item.target.reviewsPolicySubject,
        trigger: .manual,
        status: status,
        startedAt: "2026-05-29T12:00:00Z",
        updatedAt: "2026-05-29T12:00:01Z",
        errorMessage: status == .failed ? errorMessage : nil
      ),
      status: nil,
      skippedReason: nil,
      errorMessage: nil
    )
  }

  @Test("auto policy confirmation describes planned workflow steps")
  func autoPolicyConfirmationDescribesPlannedWorkflowSteps() {
    let item = reviewItem(reviewStatus: .reviewRequired, checkStatus: .pending)
    let preview = DashboardReviewsAutoPolicyPreview(
      targets: [
        DashboardReviewsAutoPolicyPreviewTarget(
          item: item,
          preview: ReviewsPolicyPreviewResponse(
            eligible: true,
            steps: [
              ReviewsPolicyPreviewStep(stepType: .action, actionKey: "reviews.approve"),
              ReviewsPolicyPreviewStep(
                stepType: .wait,
                waitingOn: ReviewsPolicyWait(eventKey: "reviews.checks_passed")
              ),
              ReviewsPolicyPreviewStep(stepType: .action, actionKey: "reviews.merge"),
            ],
            warnings: ["Merge will wait for required checks to pass."]
          )
        )
      ]
    )

    let confirmation = dashboardReviewActionConfirmation(
      for: .auto,
      items: [item],
      preview: preview,
      mergeMethod: .squash
    )

    #expect(confirmation?.confirmButtonTitle == "Start Auto Policy on 1 Pull Request")
    #expect(
      confirmation?.message.contains("configured Reviews policy workflow") == true
    )
    #expect(confirmation?.message.contains("Planned steps:") == true)
    #expect(confirmation?.message.contains("1. Approve the pull request") == true)
    #expect(confirmation?.message.contains("2. Wait for required checks to pass") == true)
    #expect(
      confirmation?.message.contains("3. Merge the pull request using Squash") == true
    )
  }
}

private func reviewItem(
  reviewStatus: ReviewReviewStatus,
  checkStatus: ReviewCheckStatus = .success
) -> ReviewItem {
  ReviewItem(
    pullRequestID: "pr-1",
    repositoryID: "repo-1",
    repository: "org-a/example",
    number: 42,
    title: "Bump dependency",
    url: "https://github.com/org-a/example/pull/42",
    authorLogin: "renovate[bot]",
    state: .open,
    mergeable: .mergeable,
    reviewStatus: reviewStatus,
    checkStatus: checkStatus,
    policyBlocked: false,
    isDraft: false,
    headSha: "abc123",
    additions: 10,
    deletions: 4,
    createdAt: "2026-05-20T10:00:00Z",
    updatedAt: "2026-05-20T11:00:00Z",
    viewerCanUpdate: true
  )
}
