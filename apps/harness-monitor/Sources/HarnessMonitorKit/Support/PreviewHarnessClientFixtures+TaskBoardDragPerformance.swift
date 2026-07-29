import Foundation

extension PreviewHarnessClient.Fixtures {
  public static let taskBoardDragPerformance = Self(
    health: HealthResponse(
      status: "ok",
      version: "14.5.0",
      pid: 4242,
      endpoint: "http://127.0.0.1:9999",
      startedAt: "2026-07-26T10:00:00Z",
      projectCount: 1,
      sessionCount: 1
    ),
    projects: PreviewFixtures.projects,
    sessions: [PreviewFixtures.summary],
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline,
    readySessionID: nil,
    detailsBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.detail],
    coreDetailsBySessionID: [:],
    timelinesBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.timeline],
    taskBoardItems:
      taskBoardDragPerformanceItems(
        status: .inbox,
        laneName: "backlog",
        titlePrefix: "Backlog drag card"
      )
      + taskBoardDragPerformanceItems(
        status: .todo,
        laneName: "todo",
        titlePrefix: "Todo drag card",
        indices: 1..<25
      )
      + taskBoardDragPerformanceItems(
        status: .planning,
        laneName: "planning",
        titlePrefix: "Planning drag card",
        indices: 0..<4
      )
  )

  private static func taskBoardDragPerformanceItems(
    status: TaskBoardStatus,
    laneName: String,
    titlePrefix: String,
    indices: Range<Int> = 0..<25
  ) -> [TaskBoardItem] {
    indices.enumerated().map { lanePosition, index in
      let suffix = String(format: "%02d", index)
      return TaskBoardItem(
        schemaVersion: 1,
        id: "perf-drag-\(laneName)-\(suffix)",
        title: "\(titlePrefix) \(suffix)",
        body: "Deterministic dense-board drag performance fixture",
        status: status,
        priority: .medium,
        tags: ["preview", "drag-performance"],
        projectId: "project-6ccf8d0a",
        targetProjectTypes: ["macos"],
        agentMode: .interactive,
        externalRefs: [],
        planning: TaskBoardPlanningState(summary: "Ready for drag performance validation"),
        workflow: nil,
        sessionId: nil,
        workItemId: nil,
        usage: TaskBoardUsage(),
        lanePosition: UInt32(lanePosition),
        laneOrigin: .manual(actor: "Harness Monitor performance preview"),
        laneSetAt: "2026-07-26T10:00:00Z",
        createdAt: "2026-07-26T10:00:00Z",
        updatedAt: "2026-07-26T10:00:00Z",
        deletedAt: nil
      )
    }
  }
}
