import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func auditTaskBoard(status: TaskBoardStatus?) async throws -> TaskBoardAuditSummary {
    record(.auditTaskBoard(status: status))
    return lock.withLock {
      if let summary = taskBoardAuditSummaryStorage {
        return summary
      }
      let items = filteredTaskBoardItems(status: status, itemId: nil)
      return TaskBoardAuditSummary(
        total: items.count,
        ready: items.count { $0.status == .todo },
        blocked: items.count { $0.status == .failed },
        deleted: 0,
        byStatus: statusCounts(for: items)
      )
    }
  }

  func taskBoardProjects(status: TaskBoardStatus?) async throws -> [TaskBoardProjectSummary] {
    record(.taskBoardProjects(status: status))
    if let error = dequeueTaskBoardProjectsError() {
      throw error
    }
    return lock.withLock {
      if let summaries = taskBoardProjectSummariesStorage {
        return summaries
      }
      // Fixtures predate the attribution column, so derive it the way the
      // daemon's backfill does rather than dropping every item from the
      // catalog.
      let grouped = Dictionary(
        grouping: filteredTaskBoardItems(status: status, itemId: nil)
          .map { $0.applyingPreviewAttribution() }
          .filter { $0.sourceProjectId != nil },
        by: \.sourceProjectId
      )
      // Walks the palette in the same order the daemon allocates, so a
      // recording shows the per-project marks a live board would.
      let palette = TaskBoardProjectColor.allCases
      let colorsByProject = Dictionary(
        uniqueKeysWithValues: grouped.keys.compactMap { $0 }.sorted().enumerated()
          .map { ($0.element, palette[$0.offset % palette.count]) }
      )
      return grouped.compactMap { key, items in
        guard let projectId = key else {
          return nil
        }
        let identity = items.first.flatMap(TaskBoardProjectSummary.inferredIdentity(from:))
        return TaskBoardProjectSummary(
          projectId: projectId,
          source: identity?.source ?? .manual,
          slug: identity?.slug ?? "unnamed project",
          displayName: nil,
          color: colorsByProject[projectId] ?? .blue,
          shape: .circle,
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
  }

  func taskBoardMachines(status: TaskBoardStatus?) async throws -> [TaskBoardMachineSummary] {
    record(.taskBoardMachines(status: status))
    return lock.withLock {
      if let summaries = taskBoardMachineSummariesStorage {
        return summaries
      }
      let grouped = Dictionary(
        grouping: filteredTaskBoardItems(status: status, itemId: nil), by: \.agentMode)
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
  }

  func taskBoardHostLocal() async throws -> TaskBoardHostMachine {
    record(.taskBoardHostLocal)
    return sampleTaskBoardHostMachine()
  }

  func taskBoardHostList() async throws -> [TaskBoardHostMachine] {
    record(.taskBoardHostList)
    return [sampleTaskBoardHostMachine()]
  }

  func setTaskBoardHostProjectTypes(
    request: TaskBoardHostSetProjectTypesRequest
  ) async throws -> TaskBoardHostMachine {
    record(.setTaskBoardHostProjectTypes(projectTypes: request.projectTypes))
    return TaskBoardHostMachine(
      id: "recording-host-local",
      label: "Recording Mac",
      projectTypes: request.projectTypes,
      agentModes: [],
      lastSeen: "2026-05-15T19:00:00Z"
    )
  }
}
