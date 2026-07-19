import Foundation
import HarnessMonitorKit
import OSLog

actor TaskBoardAutomationInspectorPresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  private var cachedInput: TaskBoardAutomationPresentationInput?
  private var cachedOutput = TaskBoardAutomationPresentation.empty

  func compute(
    input: TaskBoardAutomationPresentationInput
  ) -> TaskBoardAutomationPresentation {
    guard input != cachedInput else { return cachedOutput }

    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "task_board_automation.presentation.compute",
      id: signpostID,
      "runs=\(input.runs.count, privacy: .public)"
    )
    defer {
      Self.signposter.endInterval(
        "task_board_automation.presentation.compute",
        interval,
        "rows=\(self.cachedOutput.historyRuns.count, privacy: .public)"
      )
    }

    cachedInput = input
    cachedOutput = Self.presentation(from: input)
    return cachedOutput
  }

  private static func presentation(
    from input: TaskBoardAutomationPresentationInput
  ) -> TaskBoardAutomationPresentation {
    let snapshot = input.snapshot
    return TaskBoardAutomationPresentation(
      statePills: statePills(snapshot),
      queuePills: queuePills(snapshot?.queue),
      activeRunRows: runRows(snapshot?.activeRun, referenceDate: input.referenceDate),
      timingRows: timingRows(snapshot, referenceDate: input.referenceDate),
      revisionRows: revisionRows(snapshot),
      issueRows: issueRows(snapshot, metrics: input.metrics),
      historyRuns: input.runs.map {
        historyRow($0, referenceDate: input.referenceDate)
      },
      detail: detailPresentation(input.detail, referenceDate: input.referenceDate),
      metricRows: metricRows(input.metrics, referenceDate: input.referenceDate),
      controlAvailability: controlAvailability(input),
      isDegraded: snapshot?.effectiveState == .degraded || snapshot?.blockedReason != nil
    )
  }

  private static func statePills(
    _ snapshot: TaskBoardAutomationSnapshot?
  ) -> [TaskBoardAutomationPill] {
    guard let snapshot else { return [] }
    return [
      TaskBoardAutomationPill(
        id: "effective",
        label: "Effective",
        value: title(snapshot.effectiveState.rawValue),
        tone: effectiveStateTone(snapshot.effectiveState)
      ),
      TaskBoardAutomationPill(
        id: "desired",
        label: "Desired",
        value: title(snapshot.desiredMode.rawValue),
        tone: desiredModeTone(snapshot.desiredMode)
      ),
      TaskBoardAutomationPill(
        id: "admission",
        label: "Admission",
        value: title(snapshot.admissionState.rawValue),
        tone: admissionStateTone(snapshot.admissionState)
      ),
    ]
  }

  private static func queuePills(
    _ queue: TaskBoardAutomationQueueSummary?
  ) -> [TaskBoardAutomationPill] {
    guard let queue else { return [] }
    return [
      queuePill("ready", "Ready", queue.ready, .accent),
      queuePill("approval", "Approval", queue.awaitingApproval, .warning),
      queuePill("policy", "Policy blocked", queue.policyBlocked, .danger),
      queuePill("preparing", "Preparing", queue.preparing, .neutral),
      queuePill("retrying", "Retrying", queue.retrying, .warning),
      queuePill("starting", "Starting", queue.starting, .accent),
      queuePill("active", "Active", queue.active, .success),
      queuePill("draining", "Draining", queue.draining, .warning),
      queuePill("cleanup", "Cleanup", queue.cleanupRequired, .danger),
    ]
  }

  private static func queuePill(
    _ id: String,
    _ label: String,
    _ value: UInt,
    _ tone: TaskBoardAutomationTone
  ) -> TaskBoardAutomationPill {
    TaskBoardAutomationPill(id: id, label: label, value: String(value), tone: tone)
  }

  private static func runRows(
    _ run: TaskBoardAutomationRunInfo?,
    referenceDate: Date
  ) -> [TaskBoardAutomationValueRow] {
    guard let run else { return [] }
    return [
      valueRow("active-run-id", "Run", run.runId),
      valueRow("active-run-trigger", "Trigger", title(run.trigger.rawValue)),
      valueRow("active-run-state", "State", runStateTitle(run), tone: runTone(run)),
      valueRow("active-run-scope", "Scope", scopeTitle(run.scope)),
      valueRow("active-run-dry", "Dry run", run.dryRun ? "Yes" : "No"),
      timestampRow("active-run-started", "Started", run.startedAt, referenceDate),
      timestampRow("active-run-heartbeat", "Run heartbeat", run.heartbeatAt, referenceDate),
    ]
  }

  private static func timingRows(
    _ snapshot: TaskBoardAutomationSnapshot?,
    referenceDate: Date
  ) -> [TaskBoardAutomationValueRow] {
    guard let snapshot else { return [] }
    return [
      timestampRow("observed", "Observed", snapshot.observedAt, referenceDate),
      timestampRow("heartbeat", "Heartbeat", snapshot.heartbeatAt, referenceDate),
      timestampRow("next-run", "Next run", snapshot.nextRunAt, referenceDate),
      timestampRow("next-retry", "Provider backoff", snapshot.nextRetryAt, referenceDate),
      timestampRow("last-success", "Last success", snapshot.lastSuccessAt, referenceDate),
      timestampRow(
        "last-reconcile",
        "Reconciled",
        snapshot.lastReconciliationAt,
        referenceDate
      ),
    ]
  }

  private static func revisionRows(
    _ snapshot: TaskBoardAutomationSnapshot?
  ) -> [TaskBoardAutomationValueRow] {
    guard let snapshot else { return [] }
    return [
      valueRow("snapshot-revision", "Snapshot", String(snapshot.revision)),
      valueRow("settings-revision", "Settings", String(snapshot.settingsRevision)),
      valueRow("policy-revision", "Policy", String(snapshot.policyRevision)),
    ]
  }

  private static func issueRows(
    _ snapshot: TaskBoardAutomationSnapshot?,
    metrics: TaskBoardAutomationMetrics?
  ) -> [TaskBoardAutomationValueRow] {
    guard let snapshot else { return [] }
    return [
      valueRow(
        "blocked-reason",
        "Degraded / error",
        snapshot.blockedReason ?? "None",
        tone: snapshot.blockedReason == nil ? .neutral : .danger
      ),
      valueRow(
        "open-conflicts",
        "Open conflicts",
        metrics.map { String($0.openConflicts) } ?? "Loading…",
        tone: (metrics?.openConflicts ?? 0) == 0 ? .neutral : .danger
      ),
      valueRow(
        "failed-runs",
        "Failed runs",
        metrics.map { String($0.runsFailed) } ?? "Loading…",
        tone: (metrics?.runsFailed ?? 0) == 0 ? .neutral : .danger
      ),
      valueRow(
        "cleanup-required",
        "Cleanup required",
        String(snapshot.queue.cleanupRequired),
        tone: snapshot.queue.cleanupRequired == 0 ? .neutral : .warning
      ),
    ]
  }

  private static func historyRow(
    _ run: TaskBoardAutomationRunInfo,
    referenceDate: Date
  ) -> TaskBoardAutomationRunRow {
    TaskBoardAutomationRunRow(
      id: run.runId,
      title: run.runId,
      subtitle: "\(title(run.trigger.rawValue)) · \(scopeTitle(run.scope))",
      state: runStateTitle(run),
      startedAt: relativeTimestamp(run.startedAt, referenceDate: referenceDate),
      accessibilityTimestamp: run.startedAt,
      tone: runTone(run)
    )
  }

  private static func detailPresentation(
    _ detail: TaskBoardAutomationRunDetail?,
    referenceDate: Date
  ) -> TaskBoardAutomationRunDetailPresentation? {
    guard let detail else { return nil }
    let run = detail.run
    return TaskBoardAutomationRunDetailPresentation(
      runID: run.runId,
      rows: [
        valueRow("detail-trigger", "Trigger", title(run.trigger.rawValue)),
        valueRow("detail-state", "State", runStateTitle(run), tone: runTone(run)),
        valueRow("detail-scope", "Scope", scopeTitle(run.scope)),
        valueRow("detail-dry", "Dry run", run.dryRun ? "Yes" : "No"),
        timestampRow("detail-started", "Started", run.startedAt, referenceDate),
        timestampRow("detail-heartbeat", "Heartbeat", run.heartbeatAt, referenceDate),
        timestampRow("detail-completed", "Completed", run.completedAt, referenceDate),
      ],
      stages: detail.stages.map { stage in
        TaskBoardAutomationStageRow(
          id: "\(run.runId):\(stage.sequence)",
          sequence: stage.sequence,
          title: title(stage.stage),
          state: title(stage.state),
          summary: stage.summary,
          recordedAt: relativeTimestamp(stage.recordedAt, referenceDate: referenceDate),
          accessibilityTimestamp: stage.recordedAt,
          tone: stageTone(stage.state)
        )
      },
      errorKind: detail.errorKind.map(title),
      error: detail.error
    )
  }

  private static func metricRows(
    _ metrics: TaskBoardAutomationMetrics?,
    referenceDate: Date
  ) -> [TaskBoardAutomationValueRow] {
    guard let metrics else { return [] }
    return [
      valueRow("runs-total", "Runs", String(metrics.runsTotal)),
      valueRow("runs-running", "Running", String(metrics.runsRunning), tone: .accent),
      valueRow("runs-completed", "Completed", String(metrics.runsCompleted), tone: .success),
      valueRow("runs-noop", "No-op", String(metrics.runsNoop)),
      valueRow("runs-partial", "Partial", String(metrics.runsPartial), tone: .warning),
      valueRow("runs-failed", "Failed", String(metrics.runsFailed), tone: .danger),
      valueRow("runs-cancelled", "Cancelled", String(metrics.runsCancelled), tone: .danger),
      valueRow("conflicts", "Open conflicts", String(metrics.openConflicts), tone: .danger),
      timestampRow("captured", "Captured", metrics.capturedAt, referenceDate),
    ]
  }

  private static func controlAvailability(
    _ input: TaskBoardAutomationPresentationInput
  ) -> TaskBoardAutomationControlAvailability {
    let isStale = snapshotIsStale(input)
    let blockedReason: String?
    if !input.isOnline {
      blockedReason = "Connect to the Harness daemon to control automation"
    } else if input.snapshot == nil {
      blockedReason = "Waiting for the pushed automation status"
    } else if isStale {
      blockedReason = "Automation status is stale; wait for a fresh push update"
    } else if input.isGloballyBusy {
      blockedReason = "Another daemon action is in progress"
    } else if !input.isWriteAuthorized {
      blockedReason = "This daemon connection lacks write access"
    } else {
      blockedReason = nil
    }

    return TaskBoardAutomationControlAvailability(
      controlBlockedReason: blockedReason,
      isSnapshotStale: isStale
    )
  }

  private static func snapshotIsStale(
    _ input: TaskBoardAutomationPresentationInput
  ) -> Bool {
    guard let snapshot = input.snapshot else { return true }
    guard snapshot.desiredMode == .continuous,
      snapshot.admissionState == .accepting
    else {
      return false
    }
    guard
      let heartbeat = parseTimestamp(snapshot.heartbeatAt)
    else {
      return true
    }
    let heartbeatAge = input.referenceDate.timeIntervalSince(heartbeat)
    if heartbeatAge < -60 {
      return true
    }
    let elapsed = max(heartbeatAge, 0)
    let reportedAge = TimeInterval(snapshot.heartbeatAgeSeconds ?? 0)
    let staleThreshold = TimeInterval(max(120, input.reconcileIntervalSeconds * 3))
    return max(elapsed, reportedAge) > staleThreshold
  }
}
