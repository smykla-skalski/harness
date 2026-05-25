import Foundation

extension MobileDemoFixtures {
  static func demoSessions(
    station: MobileStationSummary,
    laptop: MobileStationSummary,
    now: Date
  ) -> [MobileSessionSummary] {
    [
      demoPRReviewSession(station: station, now: now),
      demoMobileSyncSession(laptop: laptop, now: now),
      demoVisualQASession(station: station, now: now),
      demoPrivacyKitSession(station: station, now: now),
    ]
  }

  static func demoPRReviewSession(
    station: MobileStationSummary,
    now: Date
  ) -> MobileSessionSummary {
    MobileSessionSummary(
      id: "session-pr-review",
      stationID: station.id,
      projectName: "Harness",
      title: "Review command queue receipts",
      branch: "feature/mobile-relay",
      status: "Waiting",
      activeAgentCount: 3,
      blockedAgentCount: 1,
      lastActivityAt: now.addingTimeInterval(-70),
      summary: "ACP decision blocks final security test.",
      agents: [
        MobileAgentSummary(
          id: "agent-codex-7",
          stationID: station.id,
          sessionID: "session-pr-review",
          displayName: "Codex Reviewer",
          family: .codex,
          status: "Waiting Approval",
          role: "reviewer",
          isActive: true,
          isBlocked: true,
          pendingApprovalCount: 1,
          lastActivityAt: now.addingTimeInterval(-70),
          summary: "Needs permission before validating the deployment diff."
        ),
        MobileAgentSummary(
          id: "agent-acp-1",
          stationID: station.id,
          sessionID: "session-pr-review",
          displayName: "ACP Gate",
          family: .acp,
          status: "Awaiting Review",
          role: "worker",
          isActive: true,
          isBlocked: true,
          pendingPermissionCount: 1,
          lastActivityAt: now.addingTimeInterval(-60),
          summary: "One permission batch is waiting."
        ),
        MobileAgentSummary(
          id: "agent-terminal-4",
          stationID: station.id,
          sessionID: "session-pr-review",
          displayName: "Codex TUI",
          family: .terminal,
          status: "Running",
          role: "worker",
          isActive: true,
          isBlocked: false,
          lastActivityAt: now.addingTimeInterval(-90),
          summary: "Running focused validation."
        ),
      ]
    )
  }

  static func demoMobileSyncSession(
    laptop: MobileStationSummary,
    now: Date
  ) -> MobileSessionSummary {
    MobileSessionSummary(
      id: "session-mobile-sync",
      stationID: laptop.id,
      projectName: "Harness Monitor",
      title: "Design iOS sync foundation",
      branch: "c/harness-monitor-ios-watch",
      status: "Planning",
      activeAgentCount: 2,
      blockedAgentCount: 1,
      lastActivityAt: now.addingTimeInterval(-9 * 60),
      summary: "Needs plan approval before Watch submission work.",
      agents: [
        MobileAgentSummary(
          id: "agent-plan-16",
          stationID: laptop.id,
          sessionID: "session-mobile-sync",
          displayName: "Planning Agent",
          family: .codex,
          status: "Running",
          role: "leader",
          isActive: true,
          isBlocked: false,
          lastActivityAt: now.addingTimeInterval(-9 * 60),
          summary: "Drafting the next implementation checkpoint."
        )
      ]
    )
  }

  static func demoVisualQASession(
    station: MobileStationSummary,
    now: Date
  ) -> MobileSessionSummary {
    MobileSessionSummary(
      id: "session-visual-qa",
      stationID: station.id,
      projectName: "Harness Monitor",
      title: "Polish mobile command cockpit",
      branch: "c/mobile-visual-pass",
      status: "Running",
      activeAgentCount: 2,
      blockedAgentCount: 0,
      lastActivityAt: now.addingTimeInterval(-3 * 60),
      summary: "Capturing iPhone and Watch screenshots, then tightening layout defects.",
      agents: [
        MobileAgentSummary(
          id: "agent-visual-codex",
          stationID: station.id,
          sessionID: "session-visual-qa",
          displayName: "Visual QA",
          family: .codex,
          status: "Running",
          role: "reviewer",
          isActive: true,
          isBlocked: false,
          lastActivityAt: now.addingTimeInterval(-2 * 60),
          summary: "Checking dense mobile screens for clipping and alignment."
        ),
        MobileAgentSummary(
          id: "agent-watch-runner",
          stationID: station.id,
          sessionID: "session-visual-qa",
          displayName: "Watch Runner",
          family: .terminal,
          status: "Running",
          role: "worker",
          isActive: true,
          isBlocked: false,
          lastActivityAt: now.addingTimeInterval(-3 * 60),
          summary: "Building watch and widget targets for screenshot review."
        ),
      ]
    )
  }

  static func demoPrivacyKitSession(
    station: MobileStationSummary,
    now: Date
  ) -> MobileSessionSummary {
    MobileSessionSummary(
      id: "session-privacy-kit",
      stationID: station.id,
      projectName: "Harness Monitor",
      title: "Prepare App Store privacy kit",
      branch: "c/privacy-review",
      status: "Reviewing",
      activeAgentCount: 1,
      blockedAgentCount: 0,
      lastActivityAt: now.addingTimeInterval(-5 * 60),
      summary: "Checking export, delete, retention, and review-note coverage.",
      agents: [
        MobileAgentSummary(
          id: "agent-privacy-reviewer",
          stationID: station.id,
          sessionID: "session-privacy-kit",
          displayName: "Privacy Reviewer",
          family: .codex,
          status: "Reviewing",
          role: "reviewer",
          isActive: true,
          isBlocked: false,
          lastActivityAt: now.addingTimeInterval(-5 * 60),
          summary: "Verifying App Store privacy surfaces."
        )
      ]
    )
  }
}
