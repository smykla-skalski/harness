import Foundation

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension TaskBoardAutomationPresentationTests {
  func availability(
    snapshot: TaskBoardAutomationSnapshot?,
    isOnline: Bool = true,
    isWriteAuthorized: Bool = true,
    isAdminAuthorized: Bool = true,
    isGloballyBusy: Bool = false
  ) async -> TaskBoardAutomationControlAvailability {
    let presentation = await TaskBoardAutomationInspectorPresentationWorker().compute(
      input: input(
        snapshot: snapshot,
        isOnline: isOnline,
        isWriteAuthorized: isWriteAuthorized,
        isAdminAuthorized: isAdminAuthorized,
        isGloballyBusy: isGloballyBusy
      )
    )
    return presentation.controlAvailability
  }

  func input(
    snapshot: TaskBoardAutomationSnapshot?,
    metrics: TaskBoardAutomationMetrics? = nil,
    referenceDate: Date = Date(timeIntervalSince1970: 0),
    isOnline: Bool = true,
    isWriteAuthorized: Bool = true,
    isAdminAuthorized: Bool = true,
    isGloballyBusy: Bool = false
  ) -> TaskBoardAutomationPresentationInput {
    TaskBoardAutomationPresentationInput(
      snapshot: snapshot,
      runs: [],
      selectedRunID: nil,
      detail: nil,
      metrics: metrics,
      referenceDate: referenceDate,
      reconcileIntervalSeconds: 60,
      isOnline: isOnline,
      isWriteAuthorized: isWriteAuthorized,
      isAdminAuthorized: isAdminAuthorized,
      isGloballyBusy: isGloballyBusy
    )
  }

  func presentationTrigger(observedAt: String) -> TaskBoardAutomationPresentationTrigger {
    TaskBoardAutomationPresentationTrigger(
      isActive: true,
      snapshotRevision: 1,
      snapshotObservedAt: observedAt,
      stateRevision: 0,
      referenceMinute: 0,
      reconcileIntervalSeconds: 60,
      isOnline: true,
      isWriteAuthorized: true,
      isAdminAuthorized: true,
      isGloballyBusy: false
    )
  }

  func snapshot(
    desiredMode: TaskBoardAutomationDesiredMode = .off,
    admissionState: TaskBoardAutomationAdmissionState = .stopped,
    heartbeatAgeSeconds: UInt64 = 0,
    cleanupRequired: UInt = 0,
    queue: TaskBoardAutomationQueueSummary? = nil,
    cancelableTargets: [TaskBoardAutomationCancelTarget] = [],
    cancelableTargetsTruncated: Bool = false
  ) -> TaskBoardAutomationSnapshot {
    TaskBoardAutomationSnapshot(
      revision: 1,
      desiredMode: desiredMode,
      admissionState: admissionState,
      effectiveState: .idle,
      observedAt: "1970-01-01T00:00:00Z",
      heartbeatAt: "1970-01-01T00:00:00Z",
      heartbeatAgeSeconds: heartbeatAgeSeconds,
      settingsRevision: 1,
      policyRevision: 1,
      queue: queue ?? TaskBoardAutomationQueueSummary(cleanupRequired: cleanupRequired),
      cancelableTargets: cancelableTargets,
      cancelableTargetsTruncated: cancelableTargetsTruncated
    )
  }

  func cancelTarget(
    executionID: String = "execution-7",
    cancelPending: Bool = false
  ) -> TaskBoardAutomationCancelTarget {
    TaskBoardAutomationCancelTarget(
      executionId: executionID,
      itemId: "item-7",
      workflowKind: .prReview,
      assignmentId: "assignment-7",
      hostId: "host-7",
      fencingEpoch: 7,
      actionKey: "review",
      attempt: 2,
      idempotencyKey: "idempotency-7",
      assignmentState: "running",
      expectedRecordSha256: "digest-7",
      cancelPending: cancelPending
    )
  }

  func run(id: String) -> TaskBoardAutomationRunInfo {
    TaskBoardAutomationRunInfo(
      runId: id,
      trigger: .manual,
      state: .terminal,
      outcome: .completed,
      dryRun: false,
      scope: TaskBoardAutomationScope(),
      startedAt: "1970-01-01T00:00:00Z",
      heartbeatAt: "1970-01-01T00:00:00Z",
      completedAt: "1970-01-01T00:01:00Z"
    )
  }
}
