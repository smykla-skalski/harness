import Foundation

extension PreviewHarnessClient {
  public struct Fixtures: Sendable {
    let health: HealthResponse
    let projects: [ProjectSummary]
    let sessions: [SessionSummary]
    let detail: SessionDetail?
    let timeline: [TimelineEntry]
    let readySessionID: String?
    let detailsBySessionID: [String: SessionDetail]
    let coreDetailsBySessionID: [String: SessionDetail]
    let timelinesBySessionID: [String: [TimelineEntry]]
    let agentTuisBySessionID: [String: [AgentTuiSnapshot]]
    let codexRunsBySessionID: [String: [CodexRunSnapshot]]
    let taskBoardOrchestratorSettings: TaskBoardOrchestratorSettings
    let taskBoardGitRuntimeConfig: TaskBoardGitRuntimeConfig
    let taskBoardGitIdentityDefaults: TaskBoardGitIdentityDefaults
    let taskBoardItems: [TaskBoardItem]
    let dependencyUpdatesResponse: DependencyUpdatesQueryResponse

    public init(
      health: HealthResponse,
      projects: [ProjectSummary],
      sessions: [SessionSummary],
      detail: SessionDetail?,
      timeline: [TimelineEntry],
      readySessionID: String?,
      detailsBySessionID: [String: SessionDetail],
      coreDetailsBySessionID: [String: SessionDetail],
      timelinesBySessionID: [String: [TimelineEntry]],
      agentTuisBySessionID: [String: [AgentTuiSnapshot]] = [:],
      codexRunsBySessionID: [String: [CodexRunSnapshot]] = [:],
      taskBoardOrchestratorSettings: TaskBoardOrchestratorSettings = Self
        .defaultTaskBoardOrchestratorSettings,
      taskBoardGitRuntimeConfig: TaskBoardGitRuntimeConfig = Self.defaultTaskBoardGitRuntimeConfig,
      taskBoardGitIdentityDefaults: TaskBoardGitIdentityDefaults = Self
        .defaultTaskBoardGitIdentityDefaults,
      taskBoardItems: [TaskBoardItem] = [],
      dependencyUpdatesResponse: DependencyUpdatesQueryResponse = Self.defaultDependencyUpdates
    ) {
      self.health = health
      self.projects = projects
      self.sessions = sessions
      self.detail = detail
      self.timeline = timeline
      self.readySessionID = readySessionID
      self.detailsBySessionID = detailsBySessionID
      self.coreDetailsBySessionID = coreDetailsBySessionID
      self.timelinesBySessionID = timelinesBySessionID
      self.agentTuisBySessionID = agentTuisBySessionID
      self.codexRunsBySessionID = codexRunsBySessionID
      self.taskBoardOrchestratorSettings = taskBoardOrchestratorSettings
      self.taskBoardGitRuntimeConfig = taskBoardGitRuntimeConfig
      self.taskBoardGitIdentityDefaults = taskBoardGitIdentityDefaults
      self.taskBoardItems = taskBoardItems
      self.dependencyUpdatesResponse = dependencyUpdatesResponse
    }

    func detail(for sessionID: String, scope: String?) -> SessionDetail? {
      if scope == "core", let coreDetail = coreDetailsBySessionID[sessionID] {
        return coreDetail
      }

      if let scopedDetail = detailsBySessionID[sessionID] {
        return scopedDetail
      }

      return detail
    }

    func timeline(for sessionID: String) -> [TimelineEntry] {
      timelinesBySessionID[sessionID] ?? timeline
    }
  }
}
