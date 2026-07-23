import Foundation
import HarnessMonitorKit

enum TaskBoardAutomationTone: Equatable, Sendable {
  case accent
  case danger
  case neutral
  case success
  case warning
}

struct TaskBoardAutomationPill: Identifiable, Equatable, Sendable {
  let id: String
  let label: String
  let value: String
  let tone: TaskBoardAutomationTone
}

struct TaskBoardAutomationValueRow: Identifiable, Equatable, Sendable {
  let id: String
  let label: String
  let value: String
  let accessibilityValue: String
  let tone: TaskBoardAutomationTone

  init(
    id: String,
    label: String,
    value: String,
    accessibilityValue: String? = nil,
    tone: TaskBoardAutomationTone = .neutral
  ) {
    self.id = id
    self.label = label
    self.value = value
    self.accessibilityValue = accessibilityValue ?? value
    self.tone = tone
  }
}

struct TaskBoardAutomationRunRow: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let subtitle: String
  let state: String
  let startedAt: String
  let accessibilityTimestamp: String
  let tone: TaskBoardAutomationTone
}

struct TaskBoardAutomationStageRow: Identifiable, Equatable, Sendable {
  let id: String
  let sequence: UInt64
  let title: String
  let state: String
  let summary: String?
  let recordedAt: String
  let accessibilityTimestamp: String
  let tone: TaskBoardAutomationTone
}

struct TaskBoardAutomationRunDetailPresentation: Equatable, Sendable {
  let runID: String
  let rows: [TaskBoardAutomationValueRow]
  let stages: [TaskBoardAutomationStageRow]
  let errorKind: String?
  let error: String?
}

struct TaskBoardAutomationCancelTargetPresentation: Identifiable, Equatable, Sendable {
  let id: String
  let target: TaskBoardAutomationCancelTarget
  let title: String
  let state: String
  let execution: String
  let assignment: String
  let binding: String

  var forceCancelAccessibilityLabel: String {
    "Force cancel \(title), execution \(target.executionId), on host \(target.hostId)"
  }
}

struct TaskBoardAutomationControlAvailability: Equatable, Sendable {
  let controlBlockedReason: String?
  let forceCancelBlockedReason: String?
  let isSnapshotStale: Bool
}

struct TaskBoardAutomationPresentationInput: Equatable, Sendable {
  let snapshot: TaskBoardAutomationSnapshot?
  let runs: [TaskBoardAutomationRunInfo]
  let selectedRunID: String?
  let detail: TaskBoardAutomationRunDetail?
  let metrics: TaskBoardAutomationMetrics?
  let referenceDate: Date
  let reconcileIntervalSeconds: UInt64
  let isOnline: Bool
  let isWriteAuthorized: Bool
  let isAdminAuthorized: Bool
  let isGloballyBusy: Bool

  func remainsCurrent(
    comparedWith current: Self,
    cachedAvailability: TaskBoardAutomationControlAvailability,
    currentAvailability: TaskBoardAutomationControlAvailability
  ) -> Bool {
    hasSameNonTimeInputs(as: current)
      && cachedAvailability == currentAvailability
  }

  private func hasSameNonTimeInputs(as other: Self) -> Bool {
    snapshot == other.snapshot
      && runs == other.runs
      && selectedRunID == other.selectedRunID
      && detail == other.detail
      && metrics == other.metrics
      && reconcileIntervalSeconds == other.reconcileIntervalSeconds
      && isOnline == other.isOnline
      && isWriteAuthorized == other.isWriteAuthorized
      && isAdminAuthorized == other.isAdminAuthorized
      && isGloballyBusy == other.isGloballyBusy
  }
}

struct TaskBoardAutomationPresentation: Equatable, Sendable {
  static let empty = Self(
    statePills: [],
    queuePills: [],
    activeRunRows: [],
    timingRows: [],
    revisionRows: [],
    issueRows: [],
    historyRuns: [],
    detail: nil,
    metricRows: [],
    cancelTargets: [],
    cancelTargetsTruncated: false,
    controlAvailability: TaskBoardAutomationControlAvailability(
      controlBlockedReason: "Waiting for automation status",
      forceCancelBlockedReason: "Waiting for automation status",
      isSnapshotStale: true
    ),
    isDegraded: false
  )

  let statePills: [TaskBoardAutomationPill]
  let queuePills: [TaskBoardAutomationPill]
  let activeRunRows: [TaskBoardAutomationValueRow]
  let timingRows: [TaskBoardAutomationValueRow]
  let revisionRows: [TaskBoardAutomationValueRow]
  let issueRows: [TaskBoardAutomationValueRow]
  let historyRuns: [TaskBoardAutomationRunRow]
  let detail: TaskBoardAutomationRunDetailPresentation?
  let metricRows: [TaskBoardAutomationValueRow]
  let cancelTargets: [TaskBoardAutomationCancelTargetPresentation]
  let cancelTargetsTruncated: Bool
  let controlAvailability: TaskBoardAutomationControlAvailability
  let isDegraded: Bool
}
