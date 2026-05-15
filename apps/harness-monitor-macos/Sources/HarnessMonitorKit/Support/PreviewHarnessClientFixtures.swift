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
    let taskBoardItems: [TaskBoardItem]

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
      taskBoardItems: [TaskBoardItem] = []
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
      self.taskBoardItems = taskBoardItems
    }

    public static let defaultTaskBoardOrchestratorSettings = TaskBoardOrchestratorSettings(
      enabledWorkflows: [.defaultTask, .prFix, .prReview],
      dryRunDefault: false,
      dispatchStatusFilter: .todo,
      projectDir: "/Users/example/Projects/harness",
      githubProject: TaskBoardGitHubProjectConfig(
        owner: "smykla-skalski",
        repo: "harness",
        checkoutPath: "/Users/example/Projects/harness",
        defaultBranch: "main",
        branchPrefix: "task-board/",
        mergeMethod: .squash,
        labels: TaskBoardGitHubAutomationLabels(
          managed: "task-board:managed",
          autoMerge: "task-board:auto-merge",
          needsHuman: "task-board:needs-human",
          protectedPath: "task-board:protected-path"
        ),
        protectedPaths: [TaskBoardProtectedPathRule(pattern: "docs/**")],
        enabledAutomations: TaskBoardGitHubAutomationToggles(
          enabled: [.syncTaskBoard, .createBranch, .openPullRequest, .requestReview]
        )
      ),
      policyVersion: "preview-task-board-v1"
    )

    public static let defaultTaskBoardGitRuntimeConfig = TaskBoardGitRuntimeConfig(
      global: TaskBoardGitRuntimeProfile(
        authorName: "Harness Monitor",
        authorEmail: "monitor-preview@example.com",
        sshKeyPath: "/Users/example/.ssh/id_ed25519",
        signing: TaskBoardGitSigningConfig(
          mode: .gpg,
          gpgKeyId: "ABCDEF1234567890"
        )
      ),
      repositoryOverrides: [
        TaskBoardGitRepositoryOverride(
          repository: "smykla-skalski/harness",
          profile: TaskBoardGitRuntimeProfile(
            authorName: "Bart Smykla",
            authorEmail: "bartek@smykla.com",
            sshKeyPath: "/Users/example/.ssh/id_harness",
            signing: TaskBoardGitSigningConfig(
              mode: .ssh,
              sshKeyPath: "/Users/example/.ssh/id_signing"
            )
          )
        )
      ]
    )

    private static let boardOnlyTaskBoardItem = TaskBoardItem(
      schemaVersion: 1,
      id: "preview-board-only",
      title: "Board-only preview item",
      body: "Board item without a linked session task.",
      status: .todo,
      priority: .high,
      tags: ["preview"],
      projectId: "project-6ccf8d0a",
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(summary: "Ready for board-only action validation."),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-03-28T14:05:00Z",
      updatedAt: "2026-03-28T14:06:00Z",
      deletedAt: nil
    )

    public static let populated = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 1,
        sessionCount: 1
      ),
      projects: PreviewFixtures.projects,
      sessions: [PreviewFixtures.summary],
      detail: PreviewFixtures.detail,
      timeline: PreviewFixtures.timeline,
      readySessionID: PreviewFixtures.summary.sessionId,
      detailsBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.detail],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.timeline]
    )

    public static let taskDrop = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 1,
        sessionCount: 1
      ),
      projects: PreviewFixtures.projects,
      sessions: [PreviewFixtures.taskDropSummary],
      detail: PreviewFixtures.taskDropDetail,
      timeline: PreviewFixtures.timeline,
      readySessionID: PreviewFixtures.summary.sessionId,
      detailsBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.taskDropDetail],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.timeline]
    )

    public static let dashboardLanding = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
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
      timelinesBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.timeline]
    )

    public static let taskBoardBoardOnly = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
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
      taskBoardItems: [boardOnlyTaskBoardItem]
    )

    public static let singleAgent = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 1,
        sessionCount: 1
      ),
      projects: PreviewFixtures.singleAgentProjects,
      sessions: PreviewFixtures.singleAgentSessions,
      detail: PreviewFixtures.singleAgentDetail,
      timeline: [],
      readySessionID: PreviewFixtures.singleAgentSummary.sessionId,
      detailsBySessionID: [
        PreviewFixtures.singleAgentSummary.sessionId: PreviewFixtures.singleAgentDetail
      ],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [:]
    )

    public static let emptyCockpit = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 1,
        sessionCount: 1
      ),
      projects: PreviewFixtures.projects,
      sessions: [PreviewFixtures.emptyCockpitSummary],
      detail: PreviewFixtures.emptyCockpitDetail,
      timeline: [],
      readySessionID: PreviewFixtures.emptyCockpitSummary.sessionId,
      detailsBySessionID: [
        PreviewFixtures.emptyCockpitSummary.sessionId: PreviewFixtures.emptyCockpitDetail
      ],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [PreviewFixtures.emptyCockpitSummary.sessionId: []]
    )

    public static let empty = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 0,
        sessionCount: 0
      ),
      projects: [],
      sessions: [],
      detail: nil,
      timeline: [],
      readySessionID: nil,
      detailsBySessionID: [:],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [:]
    )

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
