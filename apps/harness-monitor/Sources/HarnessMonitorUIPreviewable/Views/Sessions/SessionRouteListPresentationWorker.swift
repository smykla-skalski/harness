import Foundation
import HarnessMonitorKit
import OSLog

struct SessionAgentListPresentationInput: Equatable, Sendable {
  let agents: [AgentRegistration]
  let query: String
  let agentOrderIDs: [String]
}

struct SessionAgentListPresentation: Equatable, Sendable {
  static let empty = Self(agents: [], agentIDs: [], hasQuery: false)

  let agents: [AgentRegistration]
  let agentIDs: [String]
  let hasQuery: Bool
}

struct SessionTaskListPresentationInput: Equatable, Sendable {
  let tasks: [WorkItem]
  let query: String
}

struct SessionTaskListPresentation: Equatable, Sendable {
  static let empty = Self(tasks: [], taskIDs: [], hasQuery: false)

  let tasks: [WorkItem]
  let taskIDs: [String]
  let hasQuery: Bool
}

actor SessionRouteListPresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  private var cachedAgentInput: SessionAgentListPresentationInput?
  private var cachedAgentOutput = SessionAgentListPresentation.empty
  private var cachedTaskInput: SessionTaskListPresentationInput?
  private var cachedTaskOutput = SessionTaskListPresentation.empty

  func computeAgents(
    input: SessionAgentListPresentationInput
  ) -> SessionAgentListPresentation {
    guard input != cachedAgentInput else {
      return cachedAgentOutput
    }

    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "session_route_agents.presentation.compute",
      id: signpostID,
      "agents=\(input.agents.count, privacy: .public)"
    )
    defer {
      Self.signposter.endInterval(
        "session_route_agents.presentation.compute",
        interval,
        "visible=\(self.cachedAgentOutput.agentIDs.count, privacy: .public)"
      )
    }

    cachedAgentInput = input
    cachedAgentOutput = Self.agentPresentation(from: input)
    return cachedAgentOutput
  }

  func computeTasks(
    input: SessionTaskListPresentationInput
  ) -> SessionTaskListPresentation {
    guard input != cachedTaskInput else {
      return cachedTaskOutput
    }

    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "session_route_tasks.presentation.compute",
      id: signpostID,
      "tasks=\(input.tasks.count, privacy: .public)"
    )
    defer {
      Self.signposter.endInterval(
        "session_route_tasks.presentation.compute",
        interval,
        "visible=\(self.cachedTaskOutput.taskIDs.count, privacy: .public)"
      )
    }

    cachedTaskInput = input
    cachedTaskOutput = Self.taskPresentation(from: input)
    return cachedTaskOutput
  }

  func waitForIdle() async {}

  private static func agentPresentation(
    from input: SessionAgentListPresentationInput
  ) -> SessionAgentListPresentation {
    let trimmed = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = SessionWindowAgentFilter.filteredAgents(input.agents, query: trimmed)
    let ordered = orderedAgents(filtered, orderIDs: input.agentOrderIDs)
    return SessionAgentListPresentation(
      agents: ordered,
      agentIDs: ordered.map(\.agentId),
      hasQuery: !trimmed.isEmpty
    )
  }

  private static func taskPresentation(
    from input: SessionTaskListPresentationInput
  ) -> SessionTaskListPresentation {
    let trimmed = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
    let needle = trimmed.lowercased()
    let tasks: [WorkItem]
    if needle.isEmpty {
      tasks = input.tasks
    } else {
      tasks = input.tasks.filter { task in
        if task.title.lowercased().contains(needle) { return true }
        if let context = task.context?.lowercased(), context.contains(needle) {
          return true
        }
        if let fix = task.suggestedFix?.lowercased(), fix.contains(needle) {
          return true
        }
        if task.taskId.lowercased().contains(needle) { return true }
        return false
      }
    }
    return SessionTaskListPresentation(
      tasks: tasks,
      taskIDs: tasks.map(\.taskId),
      hasQuery: !trimmed.isEmpty
    )
  }

  private static func orderedAgents(
    _ agents: [AgentRegistration],
    orderIDs: [String]
  ) -> [AgentRegistration] {
    let liveIDs = agents.map(\.agentId)
    let liveSet = Set(liveIDs)
    let retained = orderIDs.filter { liveSet.contains($0) }
    let retainedSet = Set(retained)
    let effectiveOrder = retained + liveIDs.filter { !retainedSet.contains($0) }
    let order = Dictionary(
      uniqueKeysWithValues: effectiveOrder.enumerated().map { ($1, $0) }
    )
    return agents.sorted { left, right in
      (order[left.agentId] ?? Int.max, left.agentId)
        < (order[right.agentId] ?? Int.max, right.agentId)
    }
  }
}
