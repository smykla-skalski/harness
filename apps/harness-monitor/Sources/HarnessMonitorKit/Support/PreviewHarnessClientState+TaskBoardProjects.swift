import Foundation

extension PreviewHarnessClientState {
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
      let slug =
        slugs[projectId]?.first
        .flatMap(TaskBoardProjectSummary.inferredIdentity(from:))?.slug ?? projectId
      let organization = slug.split(separator: "/").first.map(String.init) ?? slug
      let shape =
        byOrganization[organization]
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

    let updated =
      taskBoardProjects(status: nil)
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
}
