import CryptoKit
import Foundation

extension PreviewHarnessClientState {
  /// Preview/test hook: replaces the newest-first decision history for one
  /// item id. Not part of the client protocol -- callers seed fixtures
  /// through this before exercising `taskBoardItemTriageCurrent`/`History`.
  func seedTaskBoardTriageDecisions(id: String, decisions: [TaskBoardTriageDecisionRecord]) {
    taskBoardTriageDecisionsByItemID[id] = decisions
  }

  func taskBoardItemTriageCurrent(id: String) throws -> TaskBoardTriageCurrentResponse {
    _ = try currentTaskBoardItem(id: id)
    return TaskBoardTriageCurrentResponse(
      current: taskBoardTriageDecisionsByItemID[id]?.first,
      triageOverride: taskBoardTriageOverrideByItemID[id],
      effective: effectiveTaskBoardTriageOutcome(id: id)
    )
  }

  func taskBoardItemTriageHistory(
    id: String,
    beforeGeneration: UInt64?,
    limit: UInt32?
  ) throws -> TaskBoardTriageHistoryResponse {
    _ = try currentTaskBoardItem(id: id)
    guard
      beforeGeneration.isNoneOrPositiveAndInRange,
      limit.isNoneOrValidTriageHistoryLimit
    else {
      throw HarnessMonitorAPIError.semanticServer(
        code: 400,
        semanticCode: "WORKFLOW_IO",
        message: "invalid task-board triage history params"
      )
    }
    let decisions = taskBoardTriageDecisionsByItemID[id] ?? []
    let boundedLimit = Int(limit ?? 50)
    let page =
      decisions
      .filter { decision in
        beforeGeneration.map { decision.generation < $0 } ?? true
      }
      .prefix(boundedLimit + 1)
    let hasMore = page.count > boundedLimit
    let returned = Array(page.prefix(boundedLimit))
    return TaskBoardTriageHistoryResponse(
      decisions: returned,
      nextBeforeGeneration: hasMore ? returned.last?.generation : nil
    )
  }
}

extension Optional where Wrapped == UInt64 {
  fileprivate var isNoneOrPositiveAndInRange: Bool {
    map { $0 > 0 && $0 <= UInt64(Int64.max) } ?? true
  }
}

extension Optional where Wrapped == UInt32 {
  fileprivate var isNoneOrValidTriageHistoryLimit: Bool {
    map { (1...100).contains($0) } ?? true
  }
}

extension PreviewHarnessClientState {
  static let builtinV1EvaluatorIdentity = "task_board.triage.builtin_v1"
  fileprivate static let overridePlacementProducer = "task_board.triage.override"

  func setTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardSetTriageOverrideRequest
  ) throws -> TaskBoardTriageOverrideMutationResponse {
    try requireCurrentPositionSnapshot(
      id, request.expectedItemRevision, request.expectedItemsChangeSeq)
    let current = try currentTaskBoardItem(id: id)
    try ensureTriageOverrideMutable(current)
    let shifted = applyTriageVerdictPlacement(
      request.verdict, to: current, producer: Self.overridePlacementProducer,
      preserveAnyAutomaticProducer: true)
    taskBoardTriageOverrideByItemID[id] = TaskBoardTriageOverride(
      verdict: request.verdict,
      actor: request.actor,
      reason: request.reason,
      setAt: Self.mutationTimestamp
    )
    taskBoardItemsChangeSeq += 1
    return TaskBoardTriageOverrideMutationResponse(
      snapshot: try taskBoardItemPositionSnapshot(id: id),
      shifted: shifted,
      triageOverride: taskBoardTriageOverrideByItemID[id],
      effective: effectiveTaskBoardTriageOutcome(id: id)
    )
  }

  func clearTaskBoardItemTriageOverride(
    id: String,
    request: TaskBoardClearTriageOverrideRequest
  ) throws -> TaskBoardTriageOverrideMutationResponse {
    try requireCurrentPositionSnapshot(
      id, request.expectedItemRevision, request.expectedItemsChangeSeq)
    let current = try currentTaskBoardItem(id: id)
    try ensureTriageOverrideMutable(current)
    guard taskBoardTriageOverrideByItemID[id] != nil else {
      throw HarnessMonitorAPIError.semanticServer(
        code: 400,
        semanticCode: "INVALID_TRANSITION",
        message: "Task board item has no active triage override to clear"
      )
    }
    // `ensureTriageOverrideMutable` already confirmed `current` is triage
    // eligible, so a real clear always reveals a current automatic
    // decision -- never only when a decision happened to be seeded already.
    let decision = ensurePreviewTriageDecision(for: current)
    let shifted = applyTriageVerdictPlacement(
      decision.verdict, to: current, producer: Self.builtinV1EvaluatorIdentity,
      preserveAnyAutomaticProducer: false)
    taskBoardTriageOverrideByItemID.removeValue(forKey: id)
    taskBoardItemsChangeSeq += 1
    return TaskBoardTriageOverrideMutationResponse(
      snapshot: try taskBoardItemPositionSnapshot(id: id),
      shifted: shifted,
      triageOverride: nil,
      effective: effectiveTaskBoardTriageOutcome(id: id)
    )
  }

  /// An override always wins lane outcome, even over a manual anchor.
  @discardableResult
  private func applyTriageVerdictPlacement(
    _ verdict: TriageVerdict, to item: TaskBoardItem, producer: String,
    preserveAnyAutomaticProducer: Bool
  ) -> [TaskBoardShiftedItemRevision] {
    let destinationStatus: TaskBoardStatus = verdict == .todo ? .todo : .backlog
    let manuallyPlaced: Bool
    if case .manual = item.laneOrigin {
      manuallyPlaced = true
    } else {
      manuallyPlaced = false
    }
    if manuallyPlaced {
      return applyOverridePlacementToManualAnchor(item, destinationStatus: destinationStatus)
    }
    switch verdict {
    case .todo:
      let position = materializedTodoPosition(for: item)
      if item.status.canonicalPersistedStatus == .todo, item.lanePosition == position,
        case .automatic(let existingProducer) = item.laneOrigin,
        preserveAnyAutomaticProducer || existingProducer == producer
      {
        replacePosition(
          item,
          PreviewLanePlacement(
            status: .todo,
            lanePosition: item.lanePosition,
            laneOrigin: item.laneOrigin,
            laneSetAt: item.laneSetAt
          ),
          updatedAt: Self.mutationTimestamp
        )
        return []
      }
      let shifted = shiftForSet(
        itemID: item.id,
        source: item.status.canonicalPersistedStatus,
        sourceIndex: item.lanePosition
          ?? materializedLanePosition(for: item, in: item.status.canonicalPersistedStatus),
        destination: .todo,
        destinationIndex: position
      )
      replacePosition(
        item,
        PreviewLanePlacement(
          status: .todo,
          lanePosition: position,
          laneOrigin: .automatic(producer: producer),
          laneSetAt: Self.mutationTimestamp
        ),
        updatedAt: Self.mutationTimestamp
      )
      return shifted
    case .undecided:
      // Only a live Todo membership has a lane to compact.
      let source = item.status.canonicalPersistedStatus
      let shifted: [TaskBoardShiftedItemRevision]
      if source == .todo,
        let sourceIndex = item.lanePosition ?? materializedLanePosition(for: item, in: source)
      {
        shifted = shiftLaterAnchors(in: source, after: sourceIndex, excluding: item.id)
      } else {
        shifted = []
      }
      replacePosition(
        item,
        PreviewLanePlacement(
          status: .backlog,
          lanePosition: nil,
          laneOrigin: nil,
          laneSetAt: nil
        ),
        updatedAt: Self.mutationTimestamp
      )
      return shifted
    }
  }

  /// Matches `compute_builtin_v1_todo_position_in_tx` on the daemon.
  private func materializedTodoPosition(for item: TaskBoardItem) -> UInt32 {
    let siblings = taskBoardItems.filter {
      $0.id != item.id && $0.status.canonicalPersistedStatus == .todo && $0.deletedAt == nil
    }
    var ranked = siblings.map { sibling -> TaskBoardItem in
      guard case .manual = sibling.laneOrigin else {
        return sibling.replacingPreviewPosition(
          status: sibling.status, lanePosition: nil, laneOrigin: sibling.laneOrigin,
          laneSetAt: sibling.laneSetAt, updatedAt: sibling.updatedAt)
      }
      return sibling
    }
    let candidate = item.replacingPreviewPosition(
      status: .todo, lanePosition: nil, laneOrigin: nil, laneSetAt: item.laneSetAt,
      updatedAt: item.updatedAt)
    ranked.append(candidate)
    let materialized = materializedLaneItems(ranked) ?? ranked.sorted(by: legacyWithinLaneOrder)
    return UInt32(materialized.firstIndex(where: { $0.id == item.id }) ?? materialized.count)
  }

  private func applyOverridePlacementToManualAnchor(
    _ item: TaskBoardItem, destinationStatus: TaskBoardStatus
  ) -> [TaskBoardShiftedItemRevision] {
    let sourceStatus = item.status.canonicalPersistedStatus
    guard sourceStatus != destinationStatus else {
      // Already in the override's lane -- the anchor's slot/actor/laneSetAt
      // are untouched, but the daemon still bumps the row's revision on
      // every set/clear, so this call must too.
      replacePosition(
        item,
        PreviewLanePlacement(
          status: sourceStatus,
          lanePosition: item.lanePosition,
          laneOrigin: item.laneOrigin,
          laneSetAt: item.laneSetAt
        ),
        updatedAt: Self.mutationTimestamp
      )
      return []
    }
    let requested = item.lanePosition ?? 0
    let destinationCount = UInt32(
      taskBoardItems.filter {
        $0.id != item.id && $0.status.canonicalPersistedStatus == destinationStatus
          && $0.deletedAt == nil
      }.count
    )
    let clamped = min(requested, destinationCount)
    let shifted = shiftForSet(
      itemID: item.id,
      source: sourceStatus,
      sourceIndex: item.lanePosition,
      destination: destinationStatus,
      destinationIndex: clamped
    )
    replacePosition(
      item,
      PreviewLanePlacement(
        status: destinationStatus,
        lanePosition: clamped,
        laneOrigin: item.laneOrigin,
        laneSetAt: item.laneSetAt
      ),
      updatedAt: Self.mutationTimestamp
    )
    return shifted
  }

  private func effectiveTaskBoardTriageOutcome(id: String) -> TaskBoardTriageEffectiveOutcome? {
    if let override = taskBoardTriageOverrideByItemID[id] {
      return TaskBoardTriageEffectiveOutcome(verdict: override.verdict, source: .override)
    }
    if let decision = taskBoardTriageDecisionsByItemID[id]?.first {
      return TaskBoardTriageEffectiveOutcome(verdict: decision.verdict, source: .automatic)
    }
    return nil
  }

  private func ensureTriageOverrideMutable(_ item: TaskBoardItem) throws {
    guard item.deletedAt == nil else {
      throw HarnessMonitorAPIError.server(
        code: 400, message: "Cannot override triage for a deleted task-board item")
    }
    guard item.isTriageOverrideEligible else {
      throw HarnessMonitorAPIError.semanticServer(
        code: 400,
        semanticCode: "INVALID_TRANSITION",
        message: "Task board item is not eligible for a triage override"
      )
    }
  }
}
