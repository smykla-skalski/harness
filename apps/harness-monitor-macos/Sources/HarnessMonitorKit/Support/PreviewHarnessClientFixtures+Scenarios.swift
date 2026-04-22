import Foundation

extension PreviewHarnessClient.Fixtures {
  public static let overflow: Self = {
    let sessions = PreviewFixtures.overflowSessions
    let detailsBySessionID = Dictionary(
      uniqueKeysWithValues: sessions.map { session in
        let detail =
          if session.sessionId == PreviewFixtures.summary.sessionId {
            PreviewFixtures.detail
          } else {
            PreviewFixtures.sessionDetail(session: session)
          }
        return (session.sessionId, detail)
      }
    )
    let timelinesBySessionID: [String: [TimelineEntry]] = Dictionary(
      uniqueKeysWithValues: sessions.map { session in
        let timeline: [TimelineEntry] =
          if session.sessionId == PreviewFixtures.summary.sessionId {
            PreviewFixtures.timeline
          } else {
            []
          }
        return (session.sessionId, timeline)
      }
    )
    return Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 1,
        sessionCount: sessions.count
      ),
      projects: [
        ProjectSummary(
          projectId: PreviewFixtures.summary.projectId,
          name: PreviewFixtures.summary.projectName,
          projectDir: PreviewFixtures.summary.projectDir,
          contextRoot: PreviewFixtures.summary.contextRoot,
          activeSessionCount: sessions.filter { $0.status == .active }.count,
          totalSessionCount: sessions.count
        )
      ],
      sessions: sessions,
      detail: PreviewFixtures.detail,
      timeline: PreviewFixtures.timeline,
      readySessionID: PreviewFixtures.summary.sessionId,
      detailsBySessionID: detailsBySessionID,
      coreDetailsBySessionID: [:],
      timelinesBySessionID: timelinesBySessionID
    )
  }()

  public static let toolbarCountRegression = Self(
    health: HealthResponse(
      status: "ok",
      version: "14.5.0",
      pid: 4242,
      endpoint: "http://127.0.0.1:9999",
      startedAt: "2026-03-28T14:00:00Z",
      projectCount: 42,
      worktreeCount: 5,
      sessionCount: 6
    ),
    projects: [
      ProjectSummary(
        projectId: "project-toolbar-harness",
        name: "harness",
        projectDir: "/Users/example/Projects/harness",
        contextRoot:
          "/Users/example/Library/Application Support/harness/projects/project-toolbar-harness",
        activeSessionCount: 2,
        totalSessionCount: 2,
        worktrees: [
          WorktreeSummary(
            checkoutId: "checkout-toolbar-harness",
            name: "session-title",
            checkoutRoot: "/Users/example/Projects/harness/.claude/worktrees/session-title",
            contextRoot:
              "/Users/example/Library/Application Support/harness/projects/checkout-toolbar-harness",
            activeSessionCount: 2,
            totalSessionCount: 2
          )
        ]
      ),
      ProjectSummary(
        projectId: "project-toolbar-kuma",
        name: "kuma",
        projectDir: "/Users/example/Projects/kuma",
        contextRoot:
          "/Users/example/Library/Application Support/harness/projects/project-toolbar-kuma",
        activeSessionCount: 1,
        totalSessionCount: 1,
        worktrees: [
          WorktreeSummary(
            checkoutId: "checkout-toolbar-kuma",
            name: "fix-motb",
            checkoutRoot: "/Users/example/Projects/kuma/.claude/worktrees/fix-motb",
            contextRoot:
              "/Users/example/Library/Application Support/harness/projects/checkout-toolbar-kuma",
            activeSessionCount: 1,
            totalSessionCount: 1
          )
        ]
      ),
      ProjectSummary(
        projectId: "project-toolbar-orphan",
        name: "scratch",
        projectDir: "/Users/example/Projects/scratch",
        contextRoot:
          "/Users/example/Library/Application Support/harness/projects/project-toolbar-orphan",
        activeSessionCount: 0,
        totalSessionCount: 0,
        worktrees: [
          WorktreeSummary(
            checkoutId: "checkout-toolbar-orphan",
            name: "old-worktree",
            checkoutRoot: "/Users/example/Projects/scratch/.claude/worktrees/old-worktree",
            contextRoot:
              "/Users/example/Library/Application Support/harness/projects/checkout-toolbar-orphan",
            activeSessionCount: 0,
            totalSessionCount: 0
          )
        ]
      ),
    ],
    sessions: [
      SessionSummary(
        projectId: "project-toolbar-harness",
        projectName: "harness",
        projectDir: "/Users/example/Projects/harness",
        contextRoot:
          "/Users/example/Library/Application Support/harness/sessions/harness",
        sessionId: "tbhrn001",
        worktreePath:
          "/Users/example/Library/Application Support/harness/sessions/harness/tbhrn001/workspace",
        sharedPath:
          "/Users/example/Library/Application Support/harness/sessions/harness/tbhrn001/memory",
        originPath: "/Users/example/Projects/harness/.claude/worktrees/session-title",
        branchRef: "harness/tbhrn001",
        title: "Toolbar count fix",
        context: "Primary regression session",
        status: .active,
        createdAt: "2026-03-28T14:00:00Z",
        updatedAt: "2026-03-28T14:18:00Z",
        lastActivityAt: "2026-03-28T14:18:00Z",
        leaderId: "leader-harness",
        observeId: nil,
        pendingLeaderTransfer: nil,
        metrics: SessionMetrics(
          agentCount: 2,
          activeAgentCount: 2,
          openTaskCount: 1,
          inProgressTaskCount: 1,
          blockedTaskCount: 0,
          completedTaskCount: 2
        )
      ),
      SessionSummary(
        projectId: "project-toolbar-harness",
        projectName: "harness",
        projectDir: "/Users/example/Projects/harness",
        contextRoot:
          "/Users/example/Library/Application Support/harness/sessions/harness",
        sessionId: "tbhrn002",
        worktreePath:
          "/Users/example/Library/Application Support/harness/sessions/harness/tbhrn002/workspace",
        sharedPath:
          "/Users/example/Library/Application Support/harness/sessions/harness/tbhrn002/memory",
        originPath: "/Users/example/Projects/harness/.claude/worktrees/session-title",
        branchRef: "harness/tbhrn002",
        title: "Cache sweep validation",
        context: "Secondary regression session",
        status: .active,
        createdAt: "2026-03-28T14:01:00Z",
        updatedAt: "2026-03-28T14:19:00Z",
        lastActivityAt: "2026-03-28T14:19:00Z",
        leaderId: "leader-harness",
        observeId: nil,
        pendingLeaderTransfer: nil,
        metrics: SessionMetrics(
          agentCount: 2,
          activeAgentCount: 1,
          openTaskCount: 2,
          inProgressTaskCount: 0,
          blockedTaskCount: 1,
          completedTaskCount: 1
        )
      ),
      SessionSummary(
        projectId: "project-toolbar-kuma",
        projectName: "kuma",
        projectDir: "/Users/example/Projects/kuma",
        contextRoot:
          "/Users/example/Library/Application Support/harness/sessions/kuma",
        sessionId: "tbkuma01",
        worktreePath:
          "/Users/example/Library/Application Support/harness/sessions/kuma/tbkuma01/workspace",
        sharedPath:
          "/Users/example/Library/Application Support/harness/sessions/kuma/tbkuma01/memory",
        originPath: "/Users/example/Projects/kuma/.claude/worktrees/fix-motb",
        branchRef: "harness/tbkuma01",
        title: "Kuma validation",
        context: "Cross-project summary row",
        status: .active,
        createdAt: "2026-03-28T14:02:00Z",
        updatedAt: "2026-03-28T14:20:00Z",
        lastActivityAt: "2026-03-28T14:20:00Z",
        leaderId: "leader-kuma",
        observeId: nil,
        pendingLeaderTransfer: nil,
        metrics: SessionMetrics(
          agentCount: 1,
          activeAgentCount: 1,
          openTaskCount: 1,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          completedTaskCount: 3
        )
      ),
    ],
    detail: nil,
    timeline: [],
    readySessionID: nil,
    detailsBySessionID: [:],
    coreDetailsBySessionID: [:],
    timelinesBySessionID: [:]
  )

  public static let signalRegression = Self(
    health: HealthResponse(
      status: "ok",
      version: "14.5.0",
      pid: 4242,
      endpoint: "http://127.0.0.1:9999",
      startedAt: "2026-03-28T14:00:00Z",
      projectCount: 1,
      sessionCount: PreviewFixtures.signalRegressionSessions.count
    ),
    projects: PreviewFixtures.signalRegressionProjects,
    sessions: PreviewFixtures.signalRegressionSessions,
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline,
    readySessionID: PreviewFixtures.summary.sessionId,
    detailsBySessionID: [
      PreviewFixtures.summary.sessionId: PreviewFixtures.detail,
      PreviewFixtures.signalRegressionSecondarySummary.sessionId:
        PreviewFixtures.signalRegressionSecondaryDetail,
    ],
    coreDetailsBySessionID: [
      PreviewFixtures.summary.sessionId: PreviewFixtures.signalRegressionPrimaryCoreDetail,
      PreviewFixtures.signalRegressionSecondarySummary.sessionId:
        PreviewFixtures.signalRegressionSecondaryCoreDetail,
    ],
    timelinesBySessionID: [
      PreviewFixtures.summary.sessionId: PreviewFixtures.timeline,
      PreviewFixtures.signalRegressionSecondarySummary.sessionId: [],
    ]
  )

  public static let pagedTimeline = Self(
    health: HealthResponse(
      status: "ok",
      version: "14.5.0",
      pid: 4242,
      endpoint: "http://127.0.0.1:9999",
      startedAt: "2026-03-28T14:00:00Z",
      projectCount: 1,
      sessionCount: PreviewFixtures.signalRegressionSessions.count
    ),
    projects: PreviewFixtures.signalRegressionProjects,
    sessions: PreviewFixtures.signalRegressionSessions,
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.pagedTimeline,
    readySessionID: PreviewFixtures.summary.sessionId,
    detailsBySessionID: [
      PreviewFixtures.summary.sessionId: PreviewFixtures.detail,
      PreviewFixtures.signalRegressionSecondarySummary.sessionId:
        PreviewFixtures.signalRegressionSecondaryDetail,
    ],
    coreDetailsBySessionID: [
      PreviewFixtures.summary.sessionId: PreviewFixtures.signalRegressionPrimaryCoreDetail,
      PreviewFixtures.signalRegressionSecondarySummary.sessionId:
        PreviewFixtures.signalRegressionSecondaryCoreDetail,
    ],
    timelinesBySessionID: [
      PreviewFixtures.summary.sessionId: PreviewFixtures.pagedTimeline,
      PreviewFixtures.signalRegressionSecondarySummary.sessionId: PreviewFixtures.timeline,
    ]
  )
}
