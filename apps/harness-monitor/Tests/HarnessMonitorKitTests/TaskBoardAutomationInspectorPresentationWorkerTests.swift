import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task-board automation inspector presentation worker")
struct TaskBoardAutomationPresentationTests {
  @Test("Presentation uses the current metrics and queue contract")
  func presentationUsesCurrentMetrics() async throws {
    let presentation = await TaskBoardAutomationInspectorPresentationWorker().compute(
      input: input(
        snapshot: snapshot(cleanupRequired: 3),
        metrics: TaskBoardAutomationMetrics(
          runsTotal: 12,
          runsRunning: 1,
          runsCompleted: 5,
          runsNoop: 2,
          runsPartial: 1,
          runsFailed: 1,
          runsCancelled: 2,
          openConflicts: 4,
          capturedAt: "1970-01-01T00:00:00Z"
        )
      )
    )

    #expect(
      presentation.metricRows.map(\.id) == [
        "runs-total",
        "runs-running",
        "runs-completed",
        "runs-noop",
        "runs-partial",
        "runs-failed",
        "runs-cancelled",
        "conflicts",
        "captured",
      ]
    )
    #expect(presentation.metricRows.first(where: { $0.id == "runs-partial" })?.value == "1")
    #expect(
      presentation.issueRows.first(where: { $0.id == "cleanup-required" })?.value == "3"
    )
    #expect(presentation.controlAvailability.controlBlockedReason == nil)
  }

  @Test("Controls require fresh status, connectivity, write access, and an idle daemon")
  func controlGatingUsesIndependentContract() async {
    let missing = await availability(snapshot: nil)
    let offline = await availability(snapshot: snapshot(), isOnline: false)
    let readOnly = await availability(snapshot: snapshot(), isWriteAuthorized: false)
    let operatorOnly = await availability(snapshot: snapshot(), isAdminAuthorized: false)
    let busy = await availability(snapshot: snapshot(), isGloballyBusy: true)
    #expect(missing.controlBlockedReason != nil)
    #expect(offline.controlBlockedReason != nil)
    #expect(readOnly.controlBlockedReason != nil)
    #expect(operatorOnly.controlBlockedReason == nil)
    #expect(operatorOnly.forceCancelBlockedReason == "Force cancel requires admin access")
    #expect(busy.controlBlockedReason != nil)
    #expect(busy.forceCancelBlockedReason != nil)

    let stale = await availability(
      snapshot: snapshot(
        desiredMode: .continuous,
        admissionState: .accepting,
        heartbeatAgeSeconds: 181
      )
    )
    #expect(stale.controlBlockedReason != nil)
    #expect(stale.isSnapshotStale)

    let defaultOff = await availability(snapshot: snapshot(heartbeatAgeSeconds: 3_600))
    #expect(defaultOff.controlBlockedReason == nil)
    #expect(!defaultOff.isSnapshotStale)

    let available = await availability(snapshot: snapshot())
    #expect(available.controlBlockedReason == nil)
    #expect(!available.isSnapshotStale)
    #expect(available.forceCancelBlockedReason == nil)
  }

  @Test("Force-cancel presentation preserves every exact target and truncation warning")
  func forceCancelPresentationPreservesExactTargets() async {
    let first = cancelTarget(executionID: "execution-1")
    let pending = cancelTarget(executionID: "execution-2", cancelPending: true)
    let presentation = await TaskBoardAutomationInspectorPresentationWorker().compute(
      input: input(
        snapshot: snapshot(
          cancelableTargets: [first, pending],
          cancelableTargetsTruncated: true
        )
      )
    )

    #expect(presentation.cancelTargets.map(\.target) == [first, pending])
    #expect(presentation.cancelTargets[0].execution.contains("execution-1"))
    #expect(
      presentation.cancelTargets[0].forceCancelAccessibilityLabel
        == "Force cancel item-7, execution execution-1, on host host-7"
    )
    #expect(presentation.cancelTargets[1].state == "Cancellation pending")
    #expect(presentation.cancelTargetsTruncated)
    #expect(
      !presentation.cancelTargets
        .flatMap { [$0.execution, $0.assignment, $0.binding] }
        .contains(where: { $0.contains("digest-7") })
    )
  }

  @MainActor
  @Test("History state deduplicates pages and rejects looping cursors")
  func historyStateDeduplicatesPages() throws {
    let state = TaskBoardAutomationInspectorState()
    let initial = try #require(state.beginInitialHistoryLoad(force: true))
    state.completeHistory(
      request: initial,
      response: TaskBoardAutomationHistoryResponse(
        runs: [run(id: "run-1"), run(id: "run-1")],
        nextCursor: "cursor-2",
        hasOlder: true
      )
    )

    #expect(state.runs.map(\.runId) == ["run-1"])
    #expect(state.hasOlder)

    let older = try #require(state.beginOlderHistoryLoad())
    state.completeHistory(
      request: older,
      response: TaskBoardAutomationHistoryResponse(
        runs: [run(id: "run-1"), run(id: "run-2")],
        nextCursor: "cursor-2",
        hasOlder: true
      )
    )

    #expect(state.runs.map(\.runId) == ["run-1", "run-2"])
    #expect(!state.hasOlder)
  }

  @Test("Presentation trigger tracks a fresh observation at the same revision")
  func presentationTriggerTracksSnapshotObservation() {
    let earlier = presentationTrigger(observedAt: "1970-01-01T00:00:00Z")
    let later = presentationTrigger(observedAt: "1970-01-01T00:01:00Z")

    #expect(earlier != later)
  }

  @Test("Presentation freshness ignores harmless clock updates and closes on stale heartbeat")
  func presentationFreshnessHandlesClockUpdatesSafely() {
    let worker = TaskBoardAutomationInspectorPresentationWorker.self
    let presented = input(snapshot: snapshot())
    let nextMinute = input(
      snapshot: snapshot(),
      referenceDate: Date(timeIntervalSince1970: 60)
    )
    let offline = input(snapshot: snapshot(), isOnline: false)
    let operatorOnly = input(snapshot: snapshot(), isAdminAuthorized: false)
    let presentedAvailability = worker.controlAvailability(presented)

    #expect(
      presented.remainsCurrent(
        comparedWith: nextMinute,
        cachedAvailability: presentedAvailability,
        currentAvailability: worker.controlAvailability(nextMinute)
      )
    )
    #expect(
      !presented.remainsCurrent(
        comparedWith: offline,
        cachedAvailability: presentedAvailability,
        currentAvailability: worker.controlAvailability(offline)
      )
    )
    #expect(
      !presented.remainsCurrent(
        comparedWith: operatorOnly,
        cachedAvailability: presentedAvailability,
        currentAvailability: worker.controlAvailability(operatorOnly)
      )
    )

    let continuous = snapshot(desiredMode: .continuous, admissionState: .accepting)
    let heartbeatFresh = input(snapshot: continuous)
    let heartbeatStale = input(
      snapshot: continuous,
      referenceDate: Date(timeIntervalSince1970: 181)
    )
    let freshAvailability = worker.controlAvailability(heartbeatFresh)
    let staleAvailability = worker.controlAvailability(heartbeatStale)
    #expect(freshAvailability.controlBlockedReason == nil)
    #expect(staleAvailability.controlBlockedReason != nil)
    #expect(
      !heartbeatFresh.remainsCurrent(
        comparedWith: heartbeatStale,
        cachedAvailability: freshAvailability,
        currentAvailability: staleAvailability
      )
    )
  }

  @Test("Timestamp parser accepts daemon precision and preserves invalid values")
  func timestampParserAcceptsDaemonPrecision() {
    let worker = TaskBoardAutomationInspectorPresentationWorker.self
    #expect(worker.parseTimestamp("1970-01-01T00:00:00Z") == Date(timeIntervalSince1970: 0))
    #expect(worker.parseTimestamp("1970-01-01T00:00:00.500Z") == Date(timeIntervalSince1970: 0.5))
    #expect(worker.parseTimestamp("invalid") == nil)
    #expect(
      worker.relativeTimestamp("invalid", referenceDate: Date(timeIntervalSince1970: 0))
        == "invalid"
    )
  }

  @Test("Relative timestamps distinguish future schedules from past events")
  func relativeTimestampsDistinguishFutureAndPast() {
    let worker = TaskBoardAutomationInspectorPresentationWorker.self
    let referenceDate = Date(timeIntervalSince1970: 60)

    #expect(
      worker.relativeTimestamp("1970-01-01T00:01:30Z", referenceDate: referenceDate)
        == "in <1m"
    )
    #expect(
      worker.relativeTimestamp("1970-01-01T00:01:00Z", referenceDate: referenceDate)
        == "just now"
    )
    #expect(
      worker.relativeTimestamp("1970-01-01T00:00:30Z", referenceDate: referenceDate)
        == "just now"
    )
    #expect(
      worker.relativeTimestamp("1970-01-01T00:02:00Z", referenceDate: referenceDate)
        == "in 1m"
    )
    #expect(
      worker.relativeTimestamp("1970-01-01T00:00:00Z", referenceDate: referenceDate)
        == "1m ago"
    )
  }

  @Test("Automation accessibility identifiers safely encode daemon IDs")
  func automationAccessibilityIdentifiersEncodeDynamicSegments() {
    #expect(
      TaskBoardAutomationAccessibility.runRowID(for: "run/42 ?#%")
        == "harness.task-board.automation.run.run~2F42~20~3F~23~25"
    )
    #expect(
      TaskBoardAutomationAccessibility.stageRowID(for: "run/42 ?#%:7")
        == "harness.task-board.automation.stage.run~2F42~20~3F~23~25~3A7"
    )
    #expect(
      TaskBoardAutomationAccessibility.runRowID(for: "run~2F42")
        != TaskBoardAutomationAccessibility.runRowID(for: "run/42")
    )
    #expect(
      TaskBoardAutomationAccessibility.runRowID(for: "run/a")
        != TaskBoardAutomationAccessibility.runRowID(for: "run:a")
    )
    #expect(
      TaskBoardAutomationAccessibility.runRowID(for: "Run")
        != TaskBoardAutomationAccessibility.runRowID(for: "run")
    )
    #expect(
      TaskBoardAutomationAccessibility.runRowID(for: "rún")
        == "harness.task-board.automation.run.r~C3~BAn"
    )
    #expect(
      TaskBoardAutomationAccessibility.runRowID(for: "")
        == "harness.task-board.automation.run.~"
    )
  }

  @MainActor
  @Test("Disconnect clears remote history and rejects stale completions")
  func disconnectClearsRemoteInspectorState() throws {
    let state = TaskBoardAutomationInspectorState()
    let historyRequest = try #require(state.beginInitialHistoryLoad(force: true))
    let metricsRequest = try #require(state.beginMetricsLoad(force: true))
    let staleAction = try #require(state.beginAction(.runOnce))
    let history = TaskBoardAutomationHistoryResponse(runs: [run(id: "run-1")], hasOlder: false)
    state.completeHistory(request: historyRequest, response: history)
    state.completeMetrics(
      request: metricsRequest,
      metrics: TaskBoardAutomationMetrics(runsTotal: 1)
    )

    state.pendingForceCancelTarget = cancelTarget()

    state.resetRemoteData()
    #expect(state.runs.isEmpty)
    #expect(state.metrics == nil)
    #expect(state.pendingForceCancelTarget == nil)

    let currentAction = try #require(state.beginAction(.start))
    #expect(!state.isCurrentAction(staleAction))
    #expect(state.isCurrentAction(currentAction))
    #expect(!state.completeAction(staleAction))
    #expect(state.activeAction == .start)
    #expect(state.completeAction(currentAction))

    state.completeHistory(request: historyRequest, response: history)
    state.completeMetrics(
      request: metricsRequest,
      metrics: TaskBoardAutomationMetrics(runsTotal: 1)
    )
    #expect(state.runs.isEmpty)
    #expect(state.metrics == nil)
    #expect(state.beginInitialHistoryLoad(force: false) != nil)
    #expect(state.beginMetricsLoad(force: false) != nil)
  }

  private func availability(
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

  private func input(
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

  private func presentationTrigger(observedAt: String) -> TaskBoardAutomationPresentationTrigger {
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

  private func snapshot(
    desiredMode: TaskBoardAutomationDesiredMode = .off,
    admissionState: TaskBoardAutomationAdmissionState = .stopped,
    heartbeatAgeSeconds: UInt64 = 0,
    cleanupRequired: UInt = 0,
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
      queue: TaskBoardAutomationQueueSummary(cleanupRequired: cleanupRequired),
      cancelableTargets: cancelableTargets,
      cancelableTargetsTruncated: cancelableTargetsTruncated
    )
  }

  private func cancelTarget(
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

  private func run(id: String) -> TaskBoardAutomationRunInfo {
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
