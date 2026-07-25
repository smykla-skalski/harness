import Foundation

/// The editable half of a preview project. Everything else about a project is
/// derived from the items that name it, so only what a person can change here
/// needs storing; `nil` means "still whatever the derivation says".
public struct TaskBoardProjectEdit: Equatable, Sendable {
  public var slug: String?
  public var displayName: String?
  public var color: TaskBoardProjectColor?

  public init(
    slug: String? = nil,
    displayName: String? = nil,
    color: TaskBoardProjectColor? = nil
  ) {
    self.slug = slug
    self.displayName = displayName
    self.color = color
  }
}

extension PreviewHarnessClientState {
  func currentTaskBoardItems(status: TaskBoardStatus?) -> [TaskBoardItem] {
    let expectedStatus = status?.canonicalPersistedStatus
    let items = taskBoardItems.filter { item in
      item.deletedAt == nil
        && (expectedStatus == nil || item.status.canonicalPersistedStatus == expectedStatus)
    }
    return canonicalMaterializedTaskBoardItems(items).map { $0.applyingPreviewAttribution() }
  }

  func materializedLanePosition(for item: TaskBoardItem, in status: TaskBoardStatus) -> UInt32? {
    let lane = currentTaskBoardItems(status: status)
    guard let index = lane.firstIndex(where: { $0.id == item.id }) else {
      return nil
    }
    return UInt32(exactly: index)
  }

  private func canonicalMaterializedTaskBoardItems(_ items: [TaskBoardItem]) -> [TaskBoardItem] {
    guard items.contains(where: { $0.lanePosition != nil }) else {
      return items.sorted(by: legacyTaskBoardItemOrder)
    }
    let lanes = Dictionary(grouping: items, by: { $0.status.canonicalPersistedStatus })
    return lanes.keys
      .sorted(by: taskBoardStatusOrder)
      .flatMap { status in
        let lane = lanes[status, default: []]
        return materializedLaneItems(lane) ?? lane.sorted(by: legacyTaskBoardItemOrder)
      }
  }

  /// `nil` when the anchors can't be laid out over `items.count` slots.
  func materializedLaneItems(_ items: [TaskBoardItem]) -> [TaskBoardItem]? {
    var anchors: [UInt32: TaskBoardItem] = [:]
    var defaults: [TaskBoardItem] = []
    for item in items {
      guard let position = item.lanePosition else {
        defaults.append(item)
        continue
      }
      guard Int(position) < items.count, anchors[position] == nil else {
        return nil
      }
      anchors[position] = item
    }
    defaults.sort(by: legacyWithinLaneOrder)
    var defaultIndex = 0
    var ordered: [TaskBoardItem] = []
    for slot in 0..<items.count {
      guard let position = UInt32(exactly: slot) else {
        return nil
      }
      if let anchor = anchors.removeValue(forKey: position) {
        ordered.append(anchor)
      } else {
        guard defaultIndex < defaults.count else {
          return nil
        }
        ordered.append(defaults[defaultIndex])
        defaultIndex += 1
      }
    }
    return ordered
  }

  private func legacyTaskBoardItemOrder(_ left: TaskBoardItem, _ right: TaskBoardItem) -> Bool {
    let leftStatus = left.status.canonicalPersistedStatus
    let rightStatus = right.status.canonicalPersistedStatus
    if leftStatus != rightStatus {
      return taskBoardStatusOrder(leftStatus, rightStatus)
    }
    return legacyWithinLaneOrder(left, right)
  }

  func legacyWithinLaneOrder(_ left: TaskBoardItem, _ right: TaskBoardItem) -> Bool {
    let leftPriority = taskBoardLanePriority(left.priority)
    let rightPriority = taskBoardLanePriority(right.priority)
    if leftPriority != rightPriority {
      return leftPriority > rightPriority
    }
    if left.createdAt != right.createdAt {
      return left.createdAt < right.createdAt
    }
    return left.id < right.id
  }

  private func taskBoardStatusOrder(_ left: TaskBoardStatus, _ right: TaskBoardStatus) -> Bool {
    let leftIndex = TaskBoardStatus.allCases.firstIndex(of: left) ?? TaskBoardStatus.allCases.count
    let rightIndex =
      TaskBoardStatus.allCases.firstIndex(of: right) ?? TaskBoardStatus.allCases.count
    if leftIndex != rightIndex {
      return leftIndex < rightIndex
    }
    return left.rawValue < right.rawValue
  }

  private func taskBoardLanePriority(_ priority: TaskBoardPriority) -> Int {
    switch priority {
    case .low: 0
    case .medium: 1
    case .high: 2
    case .critical: 3
    }
  }

  func currentTaskBoardItem(id: String) throws -> TaskBoardItem {
    guard let item = taskBoardItems.first(where: { $0.id == id }) else {
      throw taskBoardItemUnavailable()
    }
    return item
  }

  func createTaskBoardItem(request: TaskBoardCreateItemRequest) -> TaskBoardItem {
    let item = TaskBoardItem(
      schemaVersion: 1,
      id: request.id ?? "preview-board-\(taskBoardItems.count + 1)",
      title: request.title,
      body: request.body,
      status: .todo,
      priority: request.priority,
      tags: request.tags,
      projectId: request.projectId,
      targetProjectTypes: request.targetProjectTypes,
      agentMode: request.agentMode,
      externalRefs: request.externalRefs,
      planning: request.planning,
      workflow: request.workflow,
      sessionId: request.sessionId,
      workItemId: request.workItemId,
      usage: TaskBoardUsage(),
      createdAt: Self.mutationTimestamp,
      updatedAt: Self.mutationTimestamp,
      deletedAt: nil
    )
    taskBoardItems.append(item)
    taskBoardItemRevisions[item.id] = 1
    taskBoardItemsChangeSeq += 1
    return item
  }

  func updateTaskBoardItem(id: String, request: TaskBoardUpdateItemRequest) throws
    -> TaskBoardItem
  {
    let current = try currentTaskBoardItem(id: id)
    return replaceTaskBoardItemWithLaneTransition(current.applyingPreviewUpdate(request))
  }

  func deleteTaskBoardItem(id: String) throws -> TaskBoardItem {
    try deleteTaskBoardItemWithLaneTransition(id: id)
  }

  func beginTaskBoardPlan(id: String) throws -> TaskBoardPlanningResponse {
    try updateTaskBoardPlanning(
      id: id,
      toStatus: .planning,
      planning: TaskBoardPlanningState()
    )
  }

  func submitTaskBoardPlan(
    id: String,
    request: TaskBoardPlanSubmitRequest
  ) throws -> TaskBoardPlanningResponse {
    try updateTaskBoardPlanning(
      id: id,
      toStatus: .planReview,
      planning: TaskBoardPlanningState(summary: request.summary)
    )
  }

  func approveTaskBoardPlan(
    id: String,
    request: TaskBoardPlanApproveRequest
  ) throws -> TaskBoardPlanningResponse {
    let approvedPlanning = TaskBoardPlanningState(
      summary: try currentTaskBoardItem(id: id).planning.summary,
      approvedBy: request.approvedBy,
      approvedAt: request.approvedAt ?? Self.mutationTimestamp
    )
    return try updateTaskBoardPlanning(id: id, toStatus: .todo, planning: approvedPlanning)
  }

  func revokeTaskBoardPlan(
    id: String,
    request: TaskBoardPlanRevokeRequest
  ) throws -> TaskBoardPlanningResponse {
    let currentPlanning = try currentTaskBoardItem(id: id).planning
    let revokedPlanning = TaskBoardPlanningState(
      summary: currentPlanning.summary,
      approvedBy: nil,
      approvedAt: nil
    )
    _ = request
    return try updateTaskBoardPlanning(
      id: id,
      toStatus: .planReview,
      planning: revokedPlanning
    )
  }

  func syncTaskBoard() -> TaskBoardSyncSummary {
    TaskBoardSyncSummary(
      total: taskBoardItems.count,
      providers: [],
      operations: taskBoardItems.map { item in
        TaskBoardExternalSyncOperation(
          provider: .gitHub,
          action: .push,
          boardItemId: item.id,
          externalId: item.externalRefs.first?.externalId,
          url: item.externalRefs.first?.url,
          dryRun: true,
          applied: false
        )
      }
    )
  }

  func dispatchTaskBoard(request: TaskBoardDispatchRequest) -> TaskBoardDispatchSummary {
    var applied: [TaskBoardDispatchAppliedTask] = []
    let plans = matchingTaskBoardItems(status: request.status, itemId: request.itemId).map { item in
      let updated = item.applyingPreviewDispatch()
      if !request.dryRun {
        let appliedItem = replaceTaskBoardItemWithLaneTransition(updated)
        applied.append(
          TaskBoardDispatchAppliedTask(
            boardItemId: appliedItem.id,
            sessionId: appliedItem.sessionId ?? "preview-session-\(appliedItem.id)",
            workItemId: appliedItem.workItemId ?? "preview-task-\(appliedItem.id)",
            item: appliedItem
          )
        )
      }
      return TaskBoardDispatchPlan.previewPlan(for: item)
    }
    return TaskBoardDispatchSummary(plans: plans, applied: applied)
  }

  func auditTaskBoard(status: TaskBoardStatus?) -> TaskBoardAuditSummary {
    let items = currentTaskBoardItems(status: status)
    return TaskBoardAuditSummary(
      total: items.count,
      ready: items.count { $0.status == .todo },
      blocked: items.count { $0.status == .blocked },
      deleted: 0,
      byStatus: statusCounts(for: items)
    )
  }

  /// One outline per organization, in the order the organizations first appear,
  /// which is the rule the daemon's backfill follows.
  private static func previewShapes(
    projectIDs: [String],
    slugs: [String?: [TaskBoardItem]],
    exceedsPalette: Bool
  ) -> [String: TaskBoardProjectShape] {
    guard exceedsPalette else {
      return [:]
    }
    let shapes = TaskBoardProjectShape.allCases
    var byOrganization: [String: TaskBoardProjectShape] = [:]
    var assigned: [String: TaskBoardProjectShape] = [:]
    for projectId in projectIDs {
      let slug = slugs[projectId]?.first
        .flatMap(TaskBoardProjectSummary.inferredIdentity(from:))?.slug ?? projectId
      let organization = slug.split(separator: "/").first.map(String.init) ?? slug
      let shape = byOrganization[organization]
        ?? shapes[byOrganization.count % shapes.count]
      byOrganization[organization] = shape
      assigned[projectId] = shape
    }
    return assigned
  }

  func taskBoardProjects(status: TaskBoardStatus?) -> [TaskBoardProjectSummary] {
    let grouped = Dictionary(
      grouping: currentTaskBoardItems(status: status).filter { $0.sourceProjectId != nil },
      by: \.sourceProjectId
    )
    // The daemon hands out colors in palette order as projects register, so
    // the fixture walks the same order over a stable sort. A preview that gave
    // every project one color would hide the thing the mark exists to show.
    let palette = TaskBoardProjectColor.allCases
    let ordered = grouped.keys.compactMap { $0 }.sorted()
    let colorsByProject = Dictionary(
      uniqueKeysWithValues: ordered.enumerated()
        .map { ($0.element, palette[$0.offset % palette.count]) }
    )
    // The daemon leaves every outline at the default until the board outgrows
    // the palette, so the fixture does too. A preview wearing shapes it has not
    // earned would make the second channel look like it is always on.
    let shapesByProject = Self.previewShapes(
      projectIDs: ordered,
      slugs: grouped,
      exceedsPalette: ordered.count > palette.count
    )
    return grouped.compactMap { key, items in
      guard let projectId = key else {
        return nil
      }
      let identity = items.first.flatMap(TaskBoardProjectSummary.inferredIdentity(from:))
      let edit = taskBoardProjectEditsByID[projectId]
      return TaskBoardProjectSummary(
        projectId: projectId,
        source: identity?.source ?? .manual,
        slug: edit?.slug ?? identity?.slug ?? "unnamed project",
        displayName: edit?.displayName,
        color: edit?.color ?? colorsByProject[projectId] ?? .blue,
        shape: shapesByProject[projectId] ?? .circle,
        itemCount: items.count,
        readyCount: items.count { $0.status == .todo }
      )
    }
    .sorted { lhs, rhs in
      if lhs.readyCount == rhs.readyCount {
        return lhs.projectId < rhs.projectId
      }
      return lhs.readyCount > rhs.readyCount
    }
  }

  /// Mirrors the daemon's edit rules, including the two refusals: a request
  /// that both sets and clears, or both sets and resets, is a caller bug and a
  /// fixture that quietly picked a winner would hide it from the UI under test.
  func updateTaskBoardProject(
    request: TaskBoardProjectUpdateRequest
  ) throws -> TaskBoardProject {
    guard !(request.clearDisplayName && request.displayName != nil) else {
      throw HarnessMonitorAPIError.server(
        code: 400,
        message: "task-board project update cannot both set and clear display_name"
      )
    }
    guard !(request.resetColor && request.color != nil) else {
      throw HarnessMonitorAPIError.server(
        code: 400,
        message: "task-board project update cannot both set and reset color"
      )
    }
    guard
      let current = taskBoardProjects(status: nil)
        .first(where: { $0.projectId == request.projectId })
    else {
      throw HarnessMonitorAPIError.server(
        code: 400,
        message: "task board project '\(request.projectId)' is not registered"
      )
    }

    var edit = taskBoardProjectEditsByID[request.projectId] ?? TaskBoardProjectEdit()
    edit.slug = request.slug ?? edit.slug
    if request.clearDisplayName {
      edit.displayName = nil
    } else if let displayName = request.displayName {
      edit.displayName = displayName
    }
    // A reset drops the override and lets the derived allocation show through,
    // which is what the daemon does by re-allocating around the others.
    edit.color = request.resetColor ? nil : (request.color ?? edit.color)
    taskBoardProjectEditsByID[request.projectId] = edit

    let updated = taskBoardProjects(status: nil)
      .first { $0.projectId == request.projectId } ?? current
    return TaskBoardProject(
      projectId: updated.projectId,
      source: updated.source,
      slug: updated.slug,
      displayName: updated.displayName,
      color: updated.color,
      shape: updated.shape,
      createdAt: "2026-07-25T00:00:00Z",
      updatedAt: "2026-07-25T00:00:00Z"
    )
  }

  func taskBoardMachines(status: TaskBoardStatus?) -> [TaskBoardMachineSummary] {
    let grouped = Dictionary(grouping: currentTaskBoardItems(status: status), by: \.agentMode)
    return grouped.map { mode, items in
      TaskBoardMachineSummary(
        mode: mode,
        itemCount: items.count,
        readyCount: items.count { $0.status == .todo }
      )
    }
    .sorted { lhs, rhs in
      if lhs.readyCount == rhs.readyCount {
        return lhs.mode.title < rhs.mode.title
      }
      return lhs.readyCount > rhs.readyCount
    }
  }

  func taskBoardHostLocal() -> TaskBoardHostMachine {
    if let first = taskBoardHostRegistry.first {
      return first
    }
    let machine = TaskBoardHostMachine(
      id: "preview-host-local",
      label: "Preview Mac",
      projectTypes: [],
      agentModes: [],
      lastSeen: Self.mutationTimestamp
    )
    taskBoardHostRegistry.append(machine)
    return machine
  }

  func taskBoardHostList() -> [TaskBoardHostMachine] {
    taskBoardHostRegistry
  }

  func setTaskBoardHostProjectTypes(
    request: TaskBoardHostSetProjectTypesRequest
  ) -> TaskBoardHostMachine {
    let current = taskBoardHostLocal()
    let updated = TaskBoardHostMachine(
      id: current.id,
      label: current.label,
      projectTypes: request.projectTypes,
      agentModes: current.agentModes,
      lastSeen: Self.mutationTimestamp
    )
    if let index = taskBoardHostRegistry.firstIndex(where: { $0.id == updated.id }) {
      taskBoardHostRegistry[index] = updated
    } else {
      taskBoardHostRegistry.append(updated)
    }
    return updated
  }

  func evaluateTaskBoard(request: TaskBoardEvaluateRequest) -> TaskBoardEvaluationSummary {
    var records: [TaskBoardEvaluationRecord] = []
    for item in matchingTaskBoardItems(status: request.status, itemId: request.itemId) {
      let record = evaluateTaskBoardItem(item, dryRun: request.dryRun)
      records.append(record)
    }
    return TaskBoardEvaluationSummary.previewSummary(records: records)
  }

  func currentTaskBoardOrchestratorStatus() -> TaskBoardOrchestratorStatus {
    taskBoardOrchestratorStatus
  }

  func setTaskBoardOrchestratorRunning(_ running: Bool) -> TaskBoardOrchestratorStatus {
    taskBoardOrchestratorStatus = taskBoardOrchestratorStatus.replacingPreviewRuntime(
      running: running
    )
    return taskBoardOrchestratorStatus
  }

  func runTaskBoardOrchestratorOnce(
    request: TaskBoardOrchestratorRunOnceRequest
  ) -> TaskBoardOrchestratorStatus {
    let dryRun = request.dryRun ?? taskBoardOrchestratorSettings.dryRunDefault
    let dispatch = dispatchTaskBoard(
      request: TaskBoardDispatchRequest(
        status: request.status ?? taskBoardOrchestratorSettings.dispatchStatusFilter,
        itemId: request.itemId,
        dryRun: dryRun,
        projectDir: request.projectDir ?? taskBoardOrchestratorSettings.projectDir,
        actor: request.actor
      )
    )
    let evaluation = evaluateTaskBoard(
      request: TaskBoardEvaluateRequest(
        status: request.status,
        itemId: request.itemId,
        dryRun: dryRun
      )
    )
    taskBoardOrchestratorStatus = taskBoardOrchestratorStatus.replacingPreviewRun(
      run: TaskBoardOrchestratorRunSummary.previewRun(
        dryRun: dryRun,
        sync: syncTaskBoard(),
        dispatch: dispatch,
        evaluation: evaluation
      )
    )
    return taskBoardOrchestratorStatus
  }

  private func updateTaskBoardPlanning(
    id: String,
    toStatus: TaskBoardStatus,
    planning: TaskBoardPlanningState
  ) throws -> TaskBoardPlanningResponse {
    let current = try currentTaskBoardItem(id: id)
    let updated = current.applyingPreviewPlanning(status: toStatus, planning: planning)
    let appliedItem = replaceTaskBoardItemWithLaneTransition(updated)
    return TaskBoardPlanningResponse(
      transition: TaskBoardPlanningTransition(
        boardItemId: id,
        fromStatus: current.status,
        toStatus: toStatus,
        planning: planning
      ),
      item: appliedItem
    )
  }

  private func matchingTaskBoardItems(
    status: TaskBoardStatus?,
    itemId: String?
  ) -> [TaskBoardItem] {
    taskBoardItems.filter { item in
      item.deletedAt == nil
        && (status == nil
          || item.status.canonicalPersistedStatus == status?.canonicalPersistedStatus)
        && (itemId == nil || item.id == itemId)
    }
  }

  private func evaluateTaskBoardItem(
    _ item: TaskBoardItem,
    dryRun: Bool
  ) -> TaskBoardEvaluationRecord {
    guard item.sessionId != nil, item.workItemId != nil else {
      return item.previewEvaluationRecord(outcome: .skippedUnlinked, updated: false)
    }
    let boardStatus = item.status.previewEvaluationStatus
    let workflowStatus = item.status.previewEvaluationWorkflowStatus
    let updated = boardStatus != item.status || workflowStatus != item.workflow?.status
    let evaluated = item.applyingPreviewEvaluation(
      status: boardStatus,
      workflowStatus: workflowStatus
    )
    if updated && !dryRun {
      let appliedItem = replaceTaskBoardItemWithLaneTransition(evaluated)
      return appliedItem.previewEvaluationRecord(
        outcome: boardStatus.previewEvaluationOutcome,
        updated: true
      )
    }
    return evaluated.previewEvaluationRecord(
      outcome: boardStatus.previewEvaluationOutcome,
      updated: false
    )
  }

  func taskBoardItemUnavailable() -> HarnessMonitorAPIError {
    HarnessMonitorAPIError.server(code: 404, message: "Task board item unavailable")
  }

  private func statusCounts(for items: [TaskBoardItem]) -> [TaskBoardStatusCount] {
    let totals = Dictionary(grouping: items, by: \.status)
    return TaskBoardStatus.allCases.compactMap { status in
      guard let itemsForStatus = totals[status], !itemsForStatus.isEmpty else {
        return nil
      }
      return TaskBoardStatusCount(status: status, count: itemsForStatus.count)
    }
  }
}
