import Foundation

extension PreviewHarnessClient.Fixtures {
  public static let defaultTaskBoardGitIdentityDefaults = TaskBoardGitIdentityDefaults(
    gitConfig: TaskBoardGitConfigDefaults(
      userName: "Bart Smykla",
      userEmail: "bartek@smykla.com",
      userSigningkey: "/Users/example/.ssh/id_ed25519.pub",
      gpgFormat: "ssh",
      commitGpgsign: true,
      coreSshCommand: nil
    ),
    ghCli: TaskBoardGhCliDefaults(githubTokenPresent: true, username: "bartsmykla"),
    discoveredSshKeys: [
      TaskBoardSshKeyDiscovery(
        path: "~/.ssh/id_ed25519",
        mode: "0600",
        format: "ed25519"
      )
    ],
    envOverrides: TaskBoardEnvDefaults()
  )

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

  public static let defaultReviews = ReviewsQueryResponse(
    fetchedAt: "2026-03-28T14:20:30Z",
    fromCache: false,
    summary: ReviewsSummary(items: sampleReviewItems),
    items: sampleReviewItems
  )

  private static let sampleReviewItems: [ReviewItem] = [
    ReviewItem(
      pullRequestID: "preview-core-requested",
      repositoryID: "repo-preview-1",
      repository: "smykla-skalski/harness",
      number: 412,
      title: "feat(reviews): quiet the smart inbox row chrome",
      url: "https://github.com/smykla-skalski/harness/pull/412",
      authorLogin: "bartsmykla",
      authorAvatarURL: URL(string: "https://avatars.githubusercontent.com/u/1?v=4"),
      authorAssociation: .member,
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .reviewRequired,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc412",
      labels: ["ux", "inbox"],
      checks: [
        ReviewCheck(
          name: "ci / dashboard",
          status: .completed,
          conclusion: .success,
          checkSuiteID: "suite-412",
          detailsURL: "https://github.com/smykla-skalski/harness/actions/runs/412"
        )
      ],
      reviews: [PullRequestReview(author: "teammate", state: .commented)],
      additions: 42,
      deletions: 12,
      createdAt: "2026-03-27T10:00:00Z",
      updatedAt: "2026-03-28T14:18:00Z",
      viewerIsRequestedReviewer: true
    ),
    ReviewItem(
      pullRequestID: "preview-external-monitoring",
      repositoryID: "repo-preview-2",
      repository: "smykla-skalski/harness-monitor",
      number: 91,
      title: "fix(settings): keep repository rows stable during refresh",
      url: "https://github.com/smykla-skalski/harness-monitor/pull/91",
      authorLogin: "outside-dev",
      authorAvatarURL: URL(string: "https://avatars.githubusercontent.com/u/2?v=4"),
      authorAssociation: .contributor,
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .approved,
      checkStatus: .pending,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc091",
      labels: ["follow-up"],
      checks: [
        ReviewCheck(
          name: "ci / soak",
          status: .inProgress,
          conclusion: .none,
          checkSuiteID: "suite-91",
          detailsURL: "https://github.com/smykla-skalski/harness-monitor/actions/runs/91"
        )
      ],
      reviews: [PullRequestReview(author: "reviewer", state: .approved)],
      additions: 18,
      deletions: 6,
      createdAt: "2026-03-28T08:40:00Z",
      updatedAt: "2026-03-28T13:45:00Z"
    ),
    ReviewItem(
      pullRequestID: "preview-first-time",
      repositoryID: "repo-preview-3",
      repository: "smykla-skalski/gh-renovate-helper",
      number: 55,
      title: "feat(cli): add safer retry hints to failed runs",
      url: "https://github.com/smykla-skalski/gh-renovate-helper/pull/55",
      authorLogin: "newcomer42",
      authorAvatarURL: URL(string: "https://avatars.githubusercontent.com/u/3?v=4"),
      authorAssociation: .firstTimeContributor,
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .reviewRequired,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc055",
      labels: ["first-time", "community"],
      checks: [
        ReviewCheck(
          name: "ci / tests",
          status: .completed,
          conclusion: .success,
          checkSuiteID: "suite-55",
          detailsURL: "https://github.com/smykla-skalski/gh-renovate-helper/actions/runs/55"
        )
      ],
      reviews: [],
      additions: 27,
      deletions: 9,
      createdAt: "2026-03-28T09:20:00Z",
      updatedAt: "2026-03-28T13:30:00Z"
    ),
    ReviewItem(
      pullRequestID: "preview-dependency-clean",
      repositoryID: "repo-preview-4",
      repository: "smykla-skalski/harness-monitor",
      number: 413,
      title: "chore(deps): update swiftlint to 0.58.0",
      url: "https://github.com/smykla-skalski/harness-monitor/pull/413",
      authorLogin: "renovate[bot]",
      authorAvatarURL: URL(string: "https://avatars.githubusercontent.com/in/2740?v=4"),
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .approved,
      checkStatus: .pending,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc413",
      labels: ["dependencies", "automerge"],
      checks: [
        ReviewCheck(
          name: "ci / lint",
          status: .inProgress,
          conclusion: .none,
          checkSuiteID: "suite-413",
          detailsURL: "https://github.com/smykla-skalski/harness-monitor/actions/runs/413"
        )
      ],
      reviews: [PullRequestReview(author: "teammate", state: .approved)],
      additions: 4,
      deletions: 4,
      createdAt: "2026-03-27T16:00:00Z",
      updatedAt: "2026-03-28T11:05:00Z"
    ),
    ReviewItem(
      pullRequestID: "preview-dependency-failing",
      repositoryID: "repo-preview-5",
      repository: "smykla-skalski/harness",
      number: 414,
      title: "chore(deps): update serde_json to 1.0.138",
      url: "https://github.com/smykla-skalski/harness/pull/414",
      authorLogin: "renovate[bot]",
      authorAvatarURL: URL(string: "https://avatars.githubusercontent.com/in/2740?v=4"),
      state: .open,
      mergeable: .conflicting,
      reviewStatus: .changesRequested,
      checkStatus: .failure,
      policyBlocked: true,
      isDraft: false,
      headSha: "abc414",
      labels: ["dependencies", "needs-human"],
      checks: [
        ReviewCheck(
          name: "ci / test",
          status: .completed,
          conclusion: .failure,
          checkSuiteID: "suite-414",
          detailsURL: "https://github.com/smykla-skalski/harness/actions/runs/414"
        ),
        ReviewCheck(
          name: "Analyze (go)",
          status: .completed,
          conclusion: .success,
          checkSuiteID: "suite-414-go",
          detailsURL: "https://github.com/smykla-skalski/harness/actions/runs/414/job/2"
        ),
        ReviewCheck(
          name: "legacy/ci",
          status: .completed,
          conclusion: .failure,
        ),
      ],
      reviews: [PullRequestReview(author: "reviewer", state: .changesRequested)],
      additions: 10,
      deletions: 6,
      createdAt: "2026-03-27T16:00:00Z",
      updatedAt: "2026-03-28T11:05:00Z"
    ),
  ]

  private static let boardOnlyTaskBoardItem = TaskBoardItem(
    schemaVersion: 1,
    id: "preview-board-only",
    title: "Board-only preview item",
    body: "Board item without a linked session task",
    status: .todo,
    priority: .high,
    tags: ["preview"],
    projectId: "project-6ccf8d0a",
    targetProjectTypes: ["web"],
    agentMode: .interactive,
    externalRefs: [],
    planning: TaskBoardPlanningState(summary: "Ready for board-only action validation"),
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
}
