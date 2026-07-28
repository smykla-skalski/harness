import AppKit
import HarnessMonitorKit

@MainActor
final class TaskBoardNativeListCoordinator {
  private final class WeakTable {
    weak var value: NSTableView?

    init(_ value: NSTableView) {
      self.value = value
    }
  }

  private var gapTargetLane: TaskBoardInboxLane?
  private var tablesByLane: [TaskBoardInboxLane: WeakTable] = [:]

  func register(_ tableView: NSTableView, lane: TaskBoardInboxLane) {
    pruneTables()
    tablesByLane[lane] = WeakTable(tableView)
    // Never `.gap` — it crashes the List/NSOutlineView bridge on cross-lane exit. The
    // custom placeholder (TaskBoardCardGapModel) is the only insertion indicator now.
    Self.applyTaskBoardBehavior(to: tableView, feedbackStyle: .none)
  }

  /// Live (lane, table) pairs for the gap model to snapshot and pin. Prunes dead refs.
  var registeredTables: [(TaskBoardInboxLane, NSTableView)] {
    pruneTables()
    return tablesByLane.compactMap { lane, weak in weak.value.map { (lane, $0) } }
  }

  func beginDrag() {
    setGapTarget(nil, reason: "drag-started")
  }

  func updateGapTarget(
    _ lane: TaskBoardInboxLane?,
    reason: String
  ) {
    setGapTarget(lane, reason: reason)
  }

  func clearGapTarget(
    _ lane: TaskBoardInboxLane,
    reason: String
  ) {
    guard gapTargetLane == lane else { return }
    setGapTarget(nil, reason: reason)
  }

  func prepareForModelMutation() {
    setGapTarget(nil, reason: "before-model-mutation")
  }

  func finishDrag() {
    setGapTarget(nil, reason: "drag-finished")
  }

  @discardableResult
  func reveal(
    row: Int,
    in lane: TaskBoardInboxLane,
    remainingAttempts: Int = 4
  ) async -> Bool {
    guard row >= 0, remainingAttempts > 0 else { return false }
    if let tableView = tablesByLane[lane]?.value {
      tableView.layoutSubtreeIfNeeded()
      if row < tableView.numberOfRows {
        tableView.scrollRowToVisible(row)
        return true
      }
    }
    guard remainingAttempts > 1, !Task.isCancelled else { return false }
    do {
      try await Task.sleep(for: .milliseconds(16))
    } catch {
      return false
    }
    return await reveal(
      row: row,
      in: lane,
      remainingAttempts: remainingAttempts - 1
    )
  }

  static func applyTaskBoardBehavior(
    to tableView: NSTableView,
    feedbackStyle: NSTableView.DraggingDestinationFeedbackStyle
  ) {
    tableView.draggingDestinationFeedbackStyle = feedbackStyle
    tableView.selectionHighlightStyle = .none
    tableView.focusRingType = .none
  }

  private func setGapTarget(
    _ lane: TaskBoardInboxLane?,
    reason: String
  ) {
    guard gapTargetLane != lane else { return }
    gapTargetLane = lane
    pruneTables()
    // `.gap` is gone (it crashes); every table stays `.none`. The gap-target methods
    // remain only so existing callers compile while the custom placeholder takes over.
    for (_, table) in tablesByLane {
      table.value?.draggingDestinationFeedbackStyle = .none
    }
    traceTaskBoardCardDrag(
      "native-gap reason=\(reason) lane=\(lane?.rawValue ?? "none")"
    )
  }

  private func pruneTables() {
    tablesByLane = tablesByLane.filter { $0.value.value != nil }
  }
}
