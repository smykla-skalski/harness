import Foundation
import HarnessMonitorKit
import SwiftUI

extension TaskBoardWorkItemState {
  var displayTitle: String {
    switch self {
    case .pending: "Pending"
    case .running: "Running"
    case .awaitingReview: "Awaiting review"
    case .inReview: "In review"
    case .changesRequested: "Changes requested"
    case .blocked: "Blocked"
    case .done: "Done"
    }
  }

  /// Paired with the title everywhere it appears, so the state never reads by
  /// colour alone.
  var systemImage: String {
    switch self {
    case .pending: "clock"
    case .running: "hammer.fill"
    case .awaitingReview: "tray.and.arrow.up.fill"
    case .inReview: "eye.fill"
    case .changesRequested: "arrow.uturn.backward"
    case .blocked: "hand.raised.fill"
    case .done: "checkmark.circle.fill"
    }
  }

  var tint: Color {
    switch self {
    case .pending: HarnessMonitorTheme.secondaryInk
    case .running, .awaitingReview, .inReview, .changesRequested: HarnessMonitorTheme.caution
    case .blocked: HarnessMonitorTheme.danger
    case .done: HarnessMonitorTheme.success
    }
  }
}

/// One checkpoint with its timestamp already parsed.
///
/// The record arrives with ISO-8601 strings. Parsing them in `body` would
/// re-parse every checkpoint on every render, so the whole log is resolved once
/// when the record loads and the views only format from here.
struct TaskBoardWorkerCheckpointPresentation: Identifiable, Equatable, Sendable {
  let id: String
  let sequence: UInt64
  let actor: String
  let summary: String
  let progressPercent: UInt8?
  let recordedAt: Date?
}

/// One worker-progress record with every timestamp parsed and its checkpoint
/// log ordered newest-first, built once per load.
struct TaskBoardWorkerProgressPresentation: Equatable, Sendable {
  let progress: TaskBoardWorkItemProgress
  let updatedAt: Date?
  let completedAt: Date?
  let checkpoints: [TaskBoardWorkerCheckpointPresentation]

  @MainActor
  init(progress: TaskBoardWorkItemProgress) {
    self.progress = progress
    updatedAt = TaskBoardCardDateParsing.parse(progress.updatedAt)
    completedAt = progress.completedAt.flatMap(TaskBoardCardDateParsing.parse)
    checkpoints =
      progress
      .checkpoints
      .sorted { $0.sequence > $1.sequence }
      .map { checkpoint in
        TaskBoardWorkerCheckpointPresentation(
          id: checkpoint.checkpointId,
          sequence: checkpoint.sequence,
          actor: checkpoint.actor,
          summary: checkpoint.summary,
          progressPercent: checkpoint.progressPercent,
          recordedAt: TaskBoardCardDateParsing.parse(checkpoint.recordedAt)
        )
      }
  }
}
