import HarnessMonitorKit
import SwiftUI

private let taskBoardCardDragTracingIsEnabled: Bool = {
  HarnessMonitorUITestEnvironment.isEnabled
    || ProcessInfo.processInfo.environment["HARNESS_MONITOR_TASK_BOARD_DRAG_TRACE"] == "1"
}()

func traceTaskBoardCardDrag(_ message: @autoclosure () -> String) {
  guard taskBoardCardDragTracingIsEnabled else {
    return
  }
  let renderedMessage = message()
  HarnessMonitorLogger.swiftui.notice("task-board-drag \(renderedMessage, privacy: .public)")
}

struct TaskBoardDropSessionTrace: Equatable {
  private(set) var sessionID = ""
  private(set) var phaseCounts: [String: Int] = [:]
  private(set) var firstLocation: CGPoint?
  private(set) var lastLocation: CGPoint?
  private(set) var minimumLocation: CGPoint?
  private(set) var maximumLocation: CGPoint?
  private(set) var destinationSize: CGSize = .zero
  private(set) var firstActiveElapsedMilliseconds: Int?
  private(set) var lastElapsedMilliseconds = 0
  private(set) var itemsCount = 0
  private(set) var suggestedOperationsRawValue = 0

  mutating func record(
    sessionID: String,
    phase: String,
    location: CGPoint,
    destinationSize: CGSize,
    elapsedMilliseconds: Int,
    itemsCount: Int,
    suggestedOperationsRawValue: Int
  ) {
    self.sessionID = sessionID
    phaseCounts[phase, default: 0] += 1
    firstLocation = firstLocation ?? location
    lastLocation = location
    minimumLocation =
      minimumLocation.map {
        CGPoint(x: min($0.x, location.x), y: min($0.y, location.y))
      } ?? location
    maximumLocation =
      maximumLocation.map {
        CGPoint(x: max($0.x, location.x), y: max($0.y, location.y))
      } ?? location
    self.destinationSize = destinationSize
    if phase == "active", firstActiveElapsedMilliseconds == nil {
      firstActiveElapsedMilliseconds = elapsedMilliseconds
    }
    lastElapsedMilliseconds = elapsedMilliseconds
    self.itemsCount = itemsCount
    self.suggestedOperationsRawValue = suggestedOperationsRawValue
  }

  var summary: String {
    let phases =
      phaseCounts
      .sorted { $0.key < $1.key }
      .map { "\($0.key):\($0.value)" }
      .joined(separator: ",")
    return
      "session=\(sessionID) phases=\(phases) "
      + "first=\(point(firstLocation)) last=\(point(lastLocation)) "
      + "bounds=\(point(minimumLocation))...\(point(maximumLocation)) "
      + "size=\(Int(destinationSize.width.rounded()))x\(Int(destinationSize.height.rounded())) "
      + "first-active-ms=\(firstActiveElapsedMilliseconds.map(String.init) ?? "none") "
      + "last-ms=\(lastElapsedMilliseconds) items=\(itemsCount) "
      + "operations=\(suggestedOperationsRawValue)"
  }

  private func point(_ point: CGPoint?) -> String {
    guard let point else { return "none" }
    return "\(Int(point.x.rounded())),\(Int(point.y.rounded()))"
  }
}

@MainActor
enum TaskBoardCardDragDiagnostics {
  private static var isRecording = false
  private static var startedAt = 0.0
  private static var activeUpdates = 0
  private static var geometryUpdates = 0
  private static var hoverPhases: [String: Int] = [:]
  private static var hoverResolutions: [String: Int] = [:]
  private static var hoverMutations: [String: Int] = [:]
  private static var dropSessions: [String: TaskBoardDropSessionTrace] = [:]

  static func begin() {
    guard taskBoardCardDragTracingIsEnabled else {
      return
    }
    startedAt = ProcessInfo.processInfo.systemUptime
    activeUpdates = 0
    geometryUpdates = 0
    hoverPhases = [:]
    hoverResolutions = [:]
    hoverMutations = [:]
    dropSessions = [:]
    isRecording = true
  }

  static func recordActiveUpdate() {
    guard isRecording else { return }
    activeUpdates += 1
  }

  static func recordGeometryUpdate() {
    guard isRecording else { return }
    geometryUpdates += 1
  }

  static func recordHoverPhase(lane: String) {
    guard isRecording else { return }
    hoverPhases[lane, default: 0] += 1
  }

  static func recordHoverResolution(lane: String) {
    guard isRecording else { return }
    hoverResolutions[lane, default: 0] += 1
  }

  static func recordHoverMutation(lane: String) {
    guard isRecording else { return }
    hoverMutations[lane, default: 0] += 1
  }

  static func recordDropSession(_ session: DropSession, lane: String) {
    guard isRecording else { return }
    let phase = taskBoardDropSessionPhaseName(session.phase)
    var trace = dropSessions[lane] ?? TaskBoardDropSessionTrace()
    let isFirstActive = phase == "active" && trace.phaseCounts[phase] == nil
    trace.record(
      sessionID: String(session.id.hashValue, radix: 16),
      phase: phase,
      location: session.location,
      destinationSize: session.size,
      elapsedMilliseconds: Int(
        ((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()
      ),
      itemsCount: session.itemsCount,
      suggestedOperationsRawValue: session.suggestedOperations.rawValue
    )
    dropSessions[lane] = trace
    if phase != "active" || isFirstActive {
      traceTaskBoardCardDrag(
        "drop-session lane=\(lane) phase=\(phase) "
          + "location=\(Int(session.location.x.rounded())),"
          + "\(Int(session.location.y.rounded())) "
          + "size=\(Int(session.size.width.rounded()))x"
          + "\(Int(session.size.height.rounded()))"
      )
    }
  }

  static func finish() {
    guard isRecording else { return }
    traceTaskBoardCardDrag(
      "session-summary active=\(activeUpdates) geometry=\(geometryUpdates) "
        + "hover-phases=\(formatted(hoverPhases)) "
        + "hover-resolutions=\(formatted(hoverResolutions)) "
        + "hover-mutations=\(formatted(hoverMutations)) "
        + "drop-sessions=\(formattedDropSessions())"
    )
    isRecording = false
  }

  private static func formatted(_ counts: [String: Int]) -> String {
    counts
      .sorted { $0.key < $1.key }
      .map { "\($0.key):\($0.value)" }
      .joined(separator: ",")
  }

  private static func formattedDropSessions() -> String {
    guard !dropSessions.isEmpty else { return "none" }
    return
      dropSessions
      .sorted { $0.key < $1.key }
      .map { "\($0.key){\($0.value.summary)}" }
      .joined(separator: "|")
  }
}

/// Pure routing decision for a drag-session phase update, extracted so it stays testable without
/// a live `TaskBoardOverviewView`. The initial phase supplies the dragged IDs, so reading them
/// again during every active pointer update only adds work to the continuous interaction path.
enum TaskBoardCardDragSessionDecision: Equatable {
  case processInitial
  case clear
  case ignore
}

func taskBoardCardDragSessionDecision(
  for phase: DragSession.Phase,
  isActionInFlight: Bool
) -> TaskBoardCardDragSessionDecision {
  switch phase {
  case .initial:
    isActionInFlight ? .ignore : .processInitial
  case .active:
    .ignore
  case .ended(let operation):
    operation == .move || operation == .copy ? .ignore : .clear
  case .dataTransferCompleted:
    .clear
  @unknown default:
    .clear
  }
}

func taskBoardCardDragSessionShouldCommitGap(for phase: DragSession.Phase) -> Bool {
  guard case .ended(let operation) = phase else { return false }
  return operation == .move || operation == .copy
}

extension TaskBoardOverviewView {
  var orderedSelectedCardIDs: [TaskBoardCardID] {
    selectionModelValue.orderedSelectedIDs
  }

  /// The single API card currently being dragged. Exact lane positioning is a
  /// single-card operation; multi-card and inbox drags keep status-only moves.
  var reorderDraggedItemValue: TaskBoardCardDragItem? {
    guard
      draggedCardIDsValue.count == 1,
      case .api(let itemID) = draggedCardIDsValue[0],
      let item = currentPresentation.taskBoardItem(id: itemID)
    else {
      return nil
    }
    return .api(itemID: item.id, status: item.status, kind: item.kind)
  }

  func cardDragPayloads(
    _ cardIDs: [TaskBoardCardID]
  ) -> [TaskBoardCardDragPayload] {
    let payloads = cardIDs.compactMap(cardDragItem).map(TaskBoardCardDragPayload.init(item:))
    traceTaskBoardCardDrag(
      "payloads requested=\(cardIDs.count) produced=\(payloads.count)"
    )
    return payloads
  }

  func cardDropPlan(
    _ cardIDs: [TaskBoardCardID],
    to lane: TaskBoardInboxLane
  ) -> TaskBoardCardDropPlan? {
    TaskBoardCardDropPlan.resolve(cardDragPayloads(cardIDs), to: lane)
  }

  func updateCardDragSession(_ session: DragSession) {
    if case .active = session.phase {
      TaskBoardCardDragDiagnostics.recordActiveUpdate()
    }
    if taskBoardCardDragSessionShouldCommitGap(for: session.phase) {
      _ = commitGapDropAtPlaceholderIfNeeded(reason: "drag-session-ended")
    }
    switch taskBoardCardDragSessionDecision(
      for: session.phase,
      isActionInFlight: isActionInFlight
    ) {
    case .processInitial:
      TaskBoardCardDragDiagnostics.begin()
      traceTaskBoardCardDrag("session phase=initial")
      updateInitialCardDrag(session)
    case .clear:
      if case .ended = session.phase {
        TaskBoardCardDragDiagnostics.finish()
      }
      traceTaskBoardCardDrag("session phase=\(taskBoardCardDragPhaseName(session.phase))")
      clearTransientCardDragState()
    case .ignore:
      break
    }
  }

  private func updateInitialCardDrag(_ session: DragSession) {
    let draggedIDs = session.draggedItemIDs(for: TaskBoardCardID.self)
    traceTaskBoardCardDrag(
      "session dragged-ids=\(draggedIDs.map { String(describing: $0) }.joined(separator: ","))"
    )
    guard !draggedIDs.isEmpty else {
      return
    }
    // Starting a drag moves the focus ring to the card, same as clicking it. Preserves an
    // existing multi-selection: the whole selection travels, so the sets match and this no-ops.
    selectionModelValue.selectForDrag(draggedIDs)
    resetDropCommit()
    updateDraggedCardIDs(draggedIDs)
    nativeListCoordinatorValue.beginDrag()
    guard beginCardGap(draggedIDs: draggedIDs) else {
      clearTransientCardDragState()
      return
    }
  }

  /// Start the custom insertion gap, but only for a single API card — the exact-position
  /// drop. Multi-card, inbox, and status drags keep the lane highlight and no gap.
  private func beginCardGap(draggedIDs: [TaskBoardCardID]) -> Bool {
    guard draggedIDs.count == 1, case .api(let itemID) = draggedIDs[0] else { return true }
    var sourceLane: TaskBoardInboxLane?
    var sourceIndex = 0
    var draggedItem: TaskBoardItem?
    for lane in TaskBoardInboxLane.allCases {
      let items = currentPresentation.apiItems(in: lane)
      if let index = items.firstIndex(where: { $0.id == itemID }) {
        sourceLane = lane
        sourceIndex = index
        draggedItem = items[index]
        break
      }
    }
    guard let source = sourceLane, let item = draggedItem else { return false }
    var rowInfo: [TaskBoardInboxLane: TaskBoardLaneAPIRowInfo] = [:]
    for lane in TaskBoardInboxLane.allCases {
      rowInfo[lane] = TaskBoardLaneAPIRowInfo(
        firstRow: decisions(in: lane).count,
        count: currentPresentation.apiItems(in: lane).count
      )
    }
    cardGapModelValue.coordinator = nativeListCoordinatorValue
    cardGapModelValue.onDragReleased = {
      // SwiftUI's List sometimes ends an otherwise valid drag as `.cancel` after the
      // board remounts. The pointer tracker still proves the exact target is under the
      // mouse, so use that placeholder as the fallback destination.
      if !commitGapDropAtPlaceholderIfNeeded(reason: "mouse-release-fallback") {
        clearTransientCardDragState()
      }
    }
    cardGapModelValue.begin(
      cardID: draggedIDs[0],
      item: item,
      sourceLane: source,
      sourceAPIIndex: sourceIndex,
      // Include the source lane so a same-lane reorder shows the gap and lands where the
      // placeholder is, instead of falling back to the List's native offset.
      candidateLanes: dropCandidateLanesValue.union([source]),
      rowInfo: rowInfo
    )
    return true
  }

  private func updateDraggedCardIDs(_ cardIDs: [TaskBoardCardID]) {
    var candidates: Set<TaskBoardInboxLane> =
      Set(TaskBoardInboxLane.allCases.filter { cardDropPlan(cardIDs, to: $0) != nil })
    // A single API card can also reorder within its source lane. Advertising that lane
    // as a move destination lets AppKit report `.move`, so `.forbidden` remains a real
    // cancellation instead of doubling as the same-lane commit signal.
    if cardIDs.count == 1,
      case .api(let itemID) = cardIDs[0],
      let item = currentPresentation.taskBoardItem(id: itemID),
      let sourceLane = TaskBoardInboxLane(taskBoardItem: item)
    {
      candidates.insert(sourceLane)
    }
    cardDragRuntimeValue.begin(cardIDs: cardIDs, candidateLanes: candidates)
    traceTaskBoardCardDrag(
      "candidate-lanes ids=\(cardIDs.count) lanes="
        + TaskBoardInboxLane.allCases
        .filter(candidates.contains)
        .map(\.rawValue)
        .joined(separator: ",")
    )
  }

  /// On release, land the dragged card where the placeholder is — even when the release
  /// is outside any lane's drop target (above the columns, in a margin). Without this an
  /// off-lane release is a no-op and the card snaps back to its original position. The
  /// didCommitDrop guard means it never double-commits with the lane / fallback drop.
  @discardableResult
  private func commitGapDropAtPlaceholderIfNeeded(reason: String) -> Bool {
    guard !didCommitDropValue else {
      traceTaskBoardCardDrag("placeholder-commit skipped reason=\(reason) already-committed")
      return false
    }
    guard let target = cardGapModelValue.target,
      let cardID = cardGapModelValue.draggedCardID
    else {
      traceTaskBoardCardDrag("placeholder-commit skipped reason=\(reason) no-target")
      return false
    }
    // Only commit if the pointer still confirms the target's list. Over a collapsed
    // lane (no list) or above the lists the target is stale/sticky — let the lane's
    // own fallback drop handle it instead of landing on the wrong lane.
    guard cardGapModelValue.targetIsUnderPointer else {
      traceTaskBoardCardDrag(
        "placeholder-commit skipped reason=\(reason) lane=\(target.lane.rawValue) off-target"
      )
      return false
    }
    let payloads = cardDragPayloads([cardID])
    let offset = cardGapModelValue.insertionOffset(for: target.lane) ?? 0
    traceTaskBoardCardDrag(
      "placeholder-commit reason=\(reason) lane=\(target.lane.rawValue) offset=\(offset)"
    )
    return handleLaneDrop(payloads, to: target.lane, insertionOffset: offset)
  }

  func clearTransientCardDragState() {
    TaskBoardCardDragDiagnostics.finish()
    nativeListCoordinatorValue.finishDrag()
    cardGapModelValue.end()
    guard !draggedCardIDsValue.isEmpty || !dropCandidateLanesValue.isEmpty else {
      return
    }
    traceTaskBoardCardDrag("clearing-transient-drag-state")
    cardDragRuntimeValue.clear()
  }

  @discardableResult
  func cancelActiveCardDrag() -> Bool {
    guard cardDragRuntimeValue.isActive || cardGapModelValue.isActive else {
      return false
    }
    traceTaskBoardCardDrag("cancel-active-drag")
    clearTransientCardDragState()
    return true
  }

  private func cardDragItem(_ cardID: TaskBoardCardID) -> TaskBoardCardDragItem? {
    switch cardID {
    case .api(let itemID):
      guard let item = currentPresentation.taskBoardItem(id: itemID) else {
        return nil
      }
      return .api(itemID: item.id, status: item.status, kind: item.kind)
    case .inbox(let sessionID, let taskID):
      guard
        let item = currentPresentation.inboxItem(id: cardID)
      else {
        return nil
      }
      return .inbox(
        sessionID: sessionID,
        taskID: taskID,
        status: item.task.status,
        sourceLaneRawValue: item.lane.rawValue
      )
    }
  }
}

private func taskBoardCardDragPhaseName(_ phase: DragSession.Phase) -> String {
  switch phase {
  case .initial:
    "initial"
  case .active:
    "active"
  case .ended(let operation):
    "ended-\(String(describing: operation))"
  case .dataTransferCompleted:
    "data-transfer-completed"
  @unknown default:
    "unknown"
  }
}

private func taskBoardDropSessionPhaseName(_ phase: DropSession.Phase) -> String {
  switch phase {
  case .entering:
    "entering"
  case .active:
    "active"
  case .exiting:
    "exiting"
  case .ended(let operation):
    "ended-\(taskBoardDropOperationName(operation))"
  case .dataTransferCompleted:
    "data-transfer-completed"
  @unknown default:
    "unknown"
  }
}

private func taskBoardDropOperationName(_ operation: DropOperation) -> String {
  switch operation {
  case .cancel:
    "cancel"
  case .forbidden:
    "forbidden"
  case .copy:
    "copy"
  case .move:
    "move"
  case .delete:
    "delete"
  case .alias:
    "alias"
  @unknown default:
    "unknown"
  }
}
