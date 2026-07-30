import AppKit
import HarnessMonitorKit
import SwiftUI

/// Where a lane's API rows sit inside its backing table. API rows follow the lane's
/// decision rows and precede its inbox rows, so `firstRow` is the decision count.
struct TaskBoardLaneAPIRowInfo: Equatable {
  var firstRow: Int
  var count: Int
}

func taskBoardCardGapSourceTargetIndex(sourceIndex: Int, sourceCount: Int) -> Int {
  min(max(sourceIndex, 0), max(0, sourceCount - 1))
}

func taskBoardCardGapPointerYInSnapshotSpace(
  pointerY: CGFloat,
  snapshotReferenceY: CGFloat,
  currentReferenceY: CGFloat
) -> CGFloat {
  pointerY - (currentReferenceY - snapshotReferenceY)
}

func taskBoardCardGapInsertionIndex(
  midpoints: [CGFloat],
  currentIndex: Int?,
  pointerY: CGFloat,
  gapHeight: CGFloat
) -> Int {
  let count = midpoints.count
  guard let currentIndex else {
    return midpoints.count { $0 > pointerY }
  }
  var index = min(max(currentIndex, 0), count)
  while index > 0, pointerY > midpoints[index - 1] {
    index -= 1
  }
  while index < count, pointerY < midpoints[index] - gapHeight {
    index += 1
  }
  return index
}

@MainActor @Observable
final class TaskBoardLaneCardGapState {
  private(set) var draggedCardID: TaskBoardCardID?
  private(set) var draggedItem: TaskBoardItem?
  private(set) var displayIndex: Int?
  private(set) var insertionOffset: Int?
  private(set) var gapHeight: CGFloat = 48
  private(set) var keepsListVisible = false
  private(set) var showsMarker = false

  var isActive: Bool { draggedCardID != nil }

  func begin(
    cardID: TaskBoardCardID,
    item: TaskBoardItem,
    displayIndex: Int?,
    insertionOffset: Int?,
    gapHeight: CGFloat,
    keepsListVisible: Bool,
    showsMarker: Bool
  ) {
    self.displayIndex = displayIndex
    self.insertionOffset = insertionOffset
    self.gapHeight = gapHeight
    self.keepsListVisible = keepsListVisible
    self.showsMarker = showsMarker
    draggedItem = item
    // The ID activates the lane's drag presentation, so publish it last.
    draggedCardID = cardID
  }

  func updateDisplay(
    index: Int?,
    insertionOffset: Int?,
    showsMarker: Bool
  ) {
    if displayIndex != index {
      displayIndex = index
    }
    if self.insertionOffset != insertionOffset {
      self.insertionOffset = insertionOffset
    }
    if self.showsMarker != showsMarker {
      self.showsMarker = showsMarker
    }
  }

  func end() {
    draggedCardID = nil
    draggedItem = nil
    displayIndex = nil
    insertionOffset = nil
    keepsListVisible = false
    showsMarker = false
  }
}

/// Drives the custom insertion gap for a single-API-card drag. macOS 26 has no native
/// cross-lane gap (`.gap` crashes the List bridge and the drop-session callbacks never
/// fire inside a List — see the taskboard-dnd-macos26-recipe memory), so the dragged
/// card is rendered as a placeholder and live-reordered to the drop point. This model
/// owns the pointer targeting: a snapshot of resting API-row midpoints, translated by
/// the List's live screen origin, plus a per-frame poll of the pointer.
@MainActor @Observable
final class TaskBoardCardGapModel {
  struct Target: Equatable {
    var lane: TaskBoardInboxLane
    /// Insertion index among the lane's API items, in post-removal (visible) space.
    var index: Int
  }

  @ObservationIgnored private(set) var target: Target?
  /// Keeps the lifted item in the drag container while the visible marker is hidden.
  /// Parking at the source slot avoids the remove-without-insert state that cancels a drag.
  var displayTarget: Target? { target ?? sourceTarget }
  @ObservationIgnored private(set) var draggedCardID: TaskBoardCardID?
  /// The dragged item, so a cross-lane target lane can render its placeholder even
  /// though the item isn't in that lane's own list yet.
  @ObservationIgnored private(set) var draggedItem: TaskBoardItem?
  /// Height of the dragged card's row — the placeholder and the hysteresis push match it.
  @ObservationIgnored private(set) var gapHeight: CGFloat = 48

  @ObservationIgnored weak var coordinator: TaskBoardNativeListCoordinator?
  @ObservationIgnored private var laneStates: [TaskBoardInboxLane: TaskBoardLaneCardGapState] = [:]
  @ObservationIgnored private var sourceLane: TaskBoardInboxLane?
  @ObservationIgnored private var sourceTarget: Target?
  @ObservationIgnored private var sourceAPIIndex = 0
  @ObservationIgnored private var sourceAPICount = 0
  /// Per-lane API-row midpoints in snapshot screen space (descending). The corresponding
  /// table reference point translates pointer Y after lane, outer-scroll, or window movement.
  @ObservationIgnored private var apiMidsByLane: [TaskBoardInboxLane: [CGFloat]] = [:]
  @ObservationIgnored private var snapshotReferenceYByLane: [TaskBoardInboxLane: CGFloat] = [:]
  @ObservationIgnored private var rowInfoByLane: [TaskBoardInboxLane: TaskBoardLaneAPIRowInfo] = [:]
  @ObservationIgnored private var candidateLanes: Set<TaskBoardInboxLane> = []
  @ObservationIgnored private var tracking: Task<Void, Never>?
  @ObservationIgnored private var scrollPin: Task<Void, Never>?
  /// Called from the poll when the button releases but no terminal phase reached us.
  /// Without an accepted terminal operation, the board may only clear the drag.
  @ObservationIgnored var onDragReleased: (() -> Void)?
  @ObservationIgnored private var buttonUpTicks = 0

  /// Whether the pointer is currently over the target lane's List scroll view. Gates the
  /// release commit so it never lands on a stale (sticky) target — e.g. released over a
  /// collapsed lane (no List) or above the lists, where the target is not confirmed.
  var targetIsUnderPointer: Bool {
    guard
      let target,
      let table = coordinator?.registeredTables.first(where: { $0.0 == target.lane })?.1,
      let window = table.window
    else { return false }
    let region: NSView = table.enclosingScrollView ?? table
    let rect = window.convertToScreen(region.convert(region.visibleRect, to: nil))
    return rect.contains(NSEvent.mouseLocation)
  }

  var isActive: Bool { draggedCardID != nil }

  /// Whether the gap is live and this lane is a drop target for it (including the source
  /// lane). A candidate lane must keep its List rendered during the drag so it has a
  /// table + column anchor for hit-testing, even when dragging its only card empties it.
  func considers(_ lane: TaskBoardInboxLane) -> Bool {
    isActive && candidateLanes.contains(lane)
  }

  func state(for lane: TaskBoardInboxLane) -> TaskBoardLaneCardGapState {
    if let state = laneStates[lane] {
      return state
    }
    let state = TaskBoardLaneCardGapState()
    laneStates[lane] = state
    return state
  }

  func begin(
    cardID: TaskBoardCardID,
    item: TaskBoardItem,
    sourceLane: TaskBoardInboxLane,
    sourceAPIIndex: Int,
    candidateLanes: Set<TaskBoardInboxLane>,
    rowInfo: [TaskBoardInboxLane: TaskBoardLaneAPIRowInfo]
  ) {
    self.candidateLanes = candidateLanes
    self.sourceLane = sourceLane
    self.sourceAPIIndex = sourceAPIIndex
    self.sourceAPICount = rowInfo[sourceLane]?.count ?? 0
    self.rowInfoByLane = rowInfo
    let tables = coordinator?.registeredTables ?? []
    snapshot(tables: tables)
    let sourceTarget = Target(
      lane: sourceLane,
      index: taskBoardCardGapSourceTargetIndex(
        sourceIndex: sourceAPIIndex,
        sourceCount: sourceAPICount
      )
    )
    self.sourceTarget = sourceTarget
    target = sourceTarget
    draggedItem = item
    // Publish active state last. Any body evaluation now sees the same card ID in
    // `displayTarget`, so the drag container never observes a remove-without-insert.
    draggedCardID = cardID
    beginLaneStates()
    buttonUpTicks = 0
    suppressNativeIndicators(in: tables)
    pinScroll(in: tables, lanes: [sourceLane])
    scheduleScrollPin(lanes: [sourceLane])
    startTracking()
  }

  func end() {
    tracking?.cancel()
    tracking = nil
    scrollPin?.cancel()
    scrollPin = nil
    draggedCardID = nil
    target = nil
    draggedItem = nil
    sourceTarget = nil
    apiMidsByLane = [:]
    snapshotReferenceYByLane = [:]
    rowInfoByLane = [:]
    candidateLanes = []
    sourceLane = nil
    sourceAPIIndex = 0
    sourceAPICount = 0
    buttonUpTicks = 0
    onDragReleased = nil
    coordinator = nil
    updateLaneStatesWithoutAnimation {
      for state in laneStates.values {
        state.end()
      }
    }
  }

  /// The ORIGINAL-space insertion offset the drop should use for a lane (what
  /// `TaskBoardCardReorderPlan` expects: index into the lane's apiItems WITH the dragged
  /// card still present), or nil to fall back to the List's native offset. `target.index`
  /// is post-removal (visible) space, so for the source lane it is converted back.
  func insertionOffset(for lane: TaskBoardInboxLane) -> Int? {
    guard let target, target.lane == lane else { return nil }
    let visibleIndex = target.index
    guard lane == sourceLane else {
      // Cross-lane: the dragged card was never in this lane, so visible == original.
      return visibleIndex
    }
    let visibleCount = max(0, sourceAPICount - 1)
    if visibleIndex >= visibleCount { return sourceAPICount }  // past the last visible card
    if visibleIndex <= sourceAPIIndex { return visibleIndex }  // at/above the old slot
    return visibleIndex + 1  // below the old slot, skip it
  }

  private func startTracking() {
    tracking?.cancel()
    tracking = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        self?.updateFromMouse()
        try? await Task.sleep(for: .milliseconds(16))
      }
    }
  }

  func updateFromMouse() {
    guard draggedCardID != nil else { return }
    // Lost-drag safety net: the mouse button is no longer down but we're still "dragging"
    // (dragged out of the app / Spaces picker, AppKit cancelled the session, and no
    // `.ended` reached us — the gap stays glued to the pointer). Debounced so a normal
    // drop, where `.ended` lands within a frame or two, does not trip it.
    if NSEvent.pressedMouseButtons & 0x1 == 0 {
      buttonUpTicks += 1
      if buttonUpTicks >= 8 {
        let release = onDragReleased
        onDragReleased = nil
        release?()
      }
      return
    }
    buttonUpTicks = 0
    guard let tables = coordinator?.registeredTables else { return }
    let pointer = NSEvent.mouseLocation
    // Hit-test each lane's List SCROLL VIEW (registered via SwiftUIIntrospect). Its clip
    // view spans the full lane body even when the table content is short, so empty lanes
    // are caught too. Tables are used only for row midpoints (the insertion index).
    for (lane, table) in tables {
      guard candidateLanes.contains(lane), let window = table.window else { continue }
      let region: NSView = table.enclosingScrollView ?? table
      let screenRect = window.convertToScreen(region.convert(region.visibleRect, to: nil))
      if screenRect.contains(pointer) {
        let index = insertionIndex(for: lane, table: table, pointerY: pointer.y)
        let next = Target(lane: lane, index: index)
        updateTarget(next, tables: tables)
        return
      }
    }
    // A collapsed lane, header, or margin has no valid exact-position target. Hide the
    // marker while parking the lifted row at its source identity slot.
    updateTarget(nil, tables: tables)
  }

  // Stateful hold zone: once the slot sits at k it stays until the pointer clears the
  // midpoint of the card ABOVE it (step up) or the pushed-down midpoint of the card
  // BELOW it (step down). No oscillation by construction.
  private func insertionIndex(
    for lane: TaskBoardInboxLane,
    table: NSTableView,
    pointerY: CGFloat
  ) -> Int {
    ensureSnapshot(for: lane, table: table)
    let snapshotReferenceY = snapshotReferenceYByLane[lane] ?? pointerY
    let currentReferenceY = tableReferenceScreenY(table) ?? snapshotReferenceY
    let translatedPointerY = taskBoardCardGapPointerYInSnapshotSpace(
      pointerY: pointerY,
      snapshotReferenceY: snapshotReferenceY,
      currentReferenceY: currentReferenceY
    )
    return taskBoardCardGapInsertionIndex(
      midpoints: apiMidsByLane[lane] ?? [],
      currentIndex: target?.lane == lane ? target?.index : nil,
      pointerY: translatedPointerY,
      gapHeight: gapHeight
    )
  }

  private func snapshot(tables: [(TaskBoardInboxLane, NSTableView)]) {
    var draggedHeight: CGFloat = 48
    for (lane, table) in tables {
      guard let info = rowInfoByLane[lane], let window = table.window else { continue }
      var laneMids: [CGFloat] = []
      for offset in 0..<info.count {
        let row = info.firstRow + offset
        guard row >= 0, row < table.numberOfRows else { continue }
        let rect = table.rect(ofRow: row)
        let windowPoint = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        laneMids.append(window.convertPoint(toScreen: windowPoint).y)
        if lane == sourceLane, offset == sourceAPIIndex {
          draggedHeight = rect.height
        }
      }
      if lane == sourceLane {
        laneMids = compact(laneMids, removingIndex: sourceAPIIndex, byHeight: draggedHeight)
      }
      apiMidsByLane[lane] = laneMids
      snapshotReferenceYByLane[lane] = tableReferenceScreenY(table)
    }
    if draggedHeight > 1 { gapHeight = draggedHeight }
  }

  private func ensureSnapshot(for lane: TaskBoardInboxLane, table: NSTableView) {
    guard apiMidsByLane[lane] == nil || snapshotReferenceYByLane[lane] == nil else {
      return
    }
    guard let info = rowInfoByLane[lane], let window = table.window else {
      apiMidsByLane[lane] = []
      snapshotReferenceYByLane[lane] = tableReferenceScreenY(table)
      return
    }
    var laneMids: [CGFloat] = []
    for offset in 0..<info.count {
      let row = info.firstRow + offset
      guard row >= 0, row < table.numberOfRows else { continue }
      let rect = table.rect(ofRow: row)
      let windowPoint = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
      laneMids.append(window.convertPoint(toScreen: windowPoint).y)
    }
    if lane == sourceLane {
      laneMids = compact(laneMids, removingIndex: sourceAPIIndex, byHeight: gapHeight)
    }
    apiMidsByLane[lane] = laneMids
    snapshotReferenceYByLane[lane] = tableReferenceScreenY(table)
  }

  private func tableReferenceScreenY(_ table: NSTableView) -> CGFloat? {
    guard let window = table.window else { return nil }
    let windowPoint = table.convert(NSPoint.zero, to: nil)
    return window.convertPoint(toScreen: windowPoint).y
  }

  // Removing a card compacts the rows below it up into its slot. Drop the dragged
  // midpoint and shift every following midpoint up by the card's height (screen Y up),
  // so the snapshot matches the compacted layout the user sees during the drag.
  private func compact(_ mids: [CGFloat], removingIndex source: Int, byHeight height: CGFloat)
    -> [CGFloat]
  {
    guard source >= 0, source < mids.count else { return mids }
    var result: [CGFloat] = []
    for (index, midpoint) in mids.enumerated() where index != source {
      result.append(index < source ? midpoint : midpoint + height)
    }
    return result
  }

  // macOS 26 `.gap` crashes the List/NSOutlineView bridge on cross-lane exit; keep every
  // table at `.none` for the whole drag (the custom placeholder is the only indicator).
  private func suppressNativeIndicators(in tables: [(TaskBoardInboxLane, NSTableView)]) {
    for (_, table) in tables where table.draggingDestinationFeedbackStyle != .none {
      table.draggingDestinationFeedbackStyle = .none
    }
  }

  private func updateTarget(
    _ next: Target?,
    tables: [(TaskBoardInboxLane, NSTableView)]
  ) {
    guard target != next else { return }
    let priorLane = displayTarget?.lane
    target = next
    let affectedLanes = Set([priorLane, displayTarget?.lane].compactMap(\.self))
    updateLaneStatesWithoutAnimation {
      for lane in affectedLanes {
        updateLaneStateDisplay(for: lane)
      }
    }
    pinScroll(in: tables, lanes: affectedLanes)
    scheduleScrollPin(lanes: affectedLanes)
  }

  private func beginLaneStates() {
    guard let draggedCardID, let draggedItem else { return }
    updateLaneStatesWithoutAnimation {
      for lane in TaskBoardInboxLane.allCases {
        let display = displayTarget?.lane == lane ? displayTarget : nil
        let showsMarker = target?.lane == lane
        state(for: lane).begin(
          cardID: draggedCardID,
          item: draggedItem,
          displayIndex: display?.index,
          insertionOffset: showsMarker ? insertionOffset(for: lane) : nil,
          gapHeight: gapHeight,
          keepsListVisible: candidateLanes.contains(lane),
          showsMarker: showsMarker
        )
      }
    }
  }

  private func updateLaneStateDisplay(for lane: TaskBoardInboxLane) {
    let display = displayTarget?.lane == lane ? displayTarget : nil
    let showsMarker = target?.lane == lane
    state(for: lane).updateDisplay(
      index: display?.index,
      insertionOffset: showsMarker ? insertionOffset(for: lane) : nil,
      showsMarker: showsMarker
    )
  }

  private func updateLaneStatesWithoutAnimation(_ update: () -> Void) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      update()
    }
  }

  private func scheduleScrollPin(lanes: Set<TaskBoardInboxLane>) {
    guard !lanes.isEmpty else { return }
    scrollPin?.cancel()
    scrollPin = Task { @MainActor [weak self] in
      await Task.yield()
      guard !Task.isCancelled, let self else { return }
      self.pinScroll(in: self.coordinator?.registeredTables ?? [], lanes: lanes)
    }
  }

  // A lane whose content fits its viewport must sit at offset 0. Row churn (live reorder)
  // can leave a residual offset that creeps the top card behind the header; force it back
  // at the AppKit level. Scrolled long lanes (content taller than the clip) are left alone.
  private func pinScroll(
    in tables: [(TaskBoardInboxLane, NSTableView)],
    lanes: Set<TaskBoardInboxLane>
  ) {
    for (lane, table) in tables where lanes.contains(lane) {
      guard let scrollView = table.enclosingScrollView else { continue }
      let clip = scrollView.contentView
      let contentHeight = scrollView.documentView?.frame.height ?? 0
      guard contentHeight <= clip.bounds.height + 0.5 else { continue }
      if abs(clip.bounds.origin.y) > 0.5 {
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: 0))
        scrollView.reflectScrolledClipView(clip)
      }
    }
  }
}
