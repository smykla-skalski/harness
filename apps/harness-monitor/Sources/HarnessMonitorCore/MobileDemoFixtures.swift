import Foundation

public enum MobileDemoFixtures {
  public static func snapshot(now: Date = .now) -> MobileMirrorSnapshot {
    let station = MobileStationSummary(
      id: "station-mac-studio",
      displayName: "Mac Studio",
      state: .online,
      lastSeenAt: now.addingTimeInterval(-18),
      activeSessionCount: 4,
      needsYouCount: 5,
      commandQueueCount: 3,
      defaultStation: true
    )
    let laptop = MobileStationSummary(
      id: "station-macbook",
      displayName: "MacBook Pro",
      state: .stale,
      lastSeenAt: now.addingTimeInterval(-11 * 60),
      activeSessionCount: 1,
      needsYouCount: 1,
      commandQueueCount: 1
    )

    let permissionTarget = MobileCommandTarget(
      stationID: station.id,
      sessionID: "session-pr-review",
      agentID: "agent-codex-7",
      targetRevision: 42
    )
    let reviewTarget = MobileCommandTarget(
      stationID: station.id,
      reviewID: "review-812",
      targetRevision: 42
    )

    let attention = [
      MobileAttentionItem(
        id: "attention-acp-prod-env",
        stationID: station.id,
        kind: .acpDecision,
        severity: .critical,
        title: "Production env read requested",
        subtitle: "Codex wants access for deployment diff validation.",
        updatedAt: now.addingTimeInterval(-60),
        commandKind: .acpPermissionDecision,
        target: permissionTarget,
        commandPayload: ["batchID": "batch-prod-env", "decision": "approve_all"]
      ),
      MobileAttentionItem(
        id: "attention-review-812",
        stationID: station.id,
        kind: .pullRequest,
        severity: .warning,
        title: "PR #812 is waiting",
        subtitle: "2 files changed, checks green, merge requires confirmation.",
        updatedAt: now.addingTimeInterval(-5 * 60),
        commandKind: .pullRequestMerge,
        target: reviewTarget
      ),
      MobileAttentionItem(
        id: "attention-agent-blocked",
        stationID: laptop.id,
        kind: .blockedAgent,
        severity: .warning,
        title: "Agent blocked on plan approval",
        subtitle: "Task board needs approval before implementation.",
        updatedAt: now.addingTimeInterval(-8 * 60),
        commandKind: .taskBoardPlanApproval,
        target: MobileCommandTarget(
          stationID: laptop.id,
          sessionID: "session-mobile-sync",
          taskID: "task-16",
          targetRevision: 7
        )
      ),
      MobileAttentionItem(
        id: "attention-station-health",
        stationID: laptop.id,
        kind: .stationHealth,
        severity: .info,
        title: "MacBook relay is stale",
        subtitle: "Last mirror update was 11 minutes ago.",
        updatedAt: now.addingTimeInterval(-11 * 60)
      ),
    ]

    let sessions = [
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
        summary: "ACP decision blocks final security test."
      ),
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
        summary: "Needs plan approval before Watch submission work."
      ),
    ]

    let reviews = [
      MobileReviewSummary(
        id: "review-812",
        stationID: station.id,
        repository: "smykla-skalski/harness",
        number: 812,
        url: "https://github.com/smykla-skalski/harness/pull/812",
        title: "Add command receipt audit trail",
        author: "bart",
        state: "open",
        checksSummary: "8/8 checks green",
        headSha: "abc123",
        mergeable: "mergeable",
        reviewStatus: "review_required",
        checkStatus: "success",
        policyBlocked: false,
        isDraft: false,
        needsYou: true,
        updatedAt: now.addingTimeInterval(-5 * 60)
      ),
      MobileReviewSummary(
        id: "review-804",
        stationID: station.id,
        repository: "smykla-skalski/harness",
        number: 804,
        url: "https://github.com/smykla-skalski/harness/pull/804",
        title: "Tighten replay protection tests",
        author: "codex",
        state: "open",
        checksSummary: "2 checks running",
        headSha: "def456",
        mergeable: "unknown",
        reviewStatus: "none",
        checkStatus: "pending",
        policyBlocked: false,
        isDraft: true,
        needsYou: false,
        updatedAt: now.addingTimeInterval(-19 * 60)
      ),
    ]

    let commands = [
      MobileCommandRecord(
        id: "command-approve-plan",
        stationID: laptop.id,
        kind: .taskBoardPlanApproval,
        risk: .high,
        status: .queued,
        title: "Approve mobile sync plan",
        confirmationText: "Approve plan for Harness Monitor iOS sync work.",
        auditReason: "Plan reviewed from mobile demo station.",
        target: MobileCommandTarget(
          stationID: laptop.id,
          sessionID: "session-mobile-sync",
          taskID: "task-16",
          targetRevision: 7
        ),
        actorDeviceID: "device-demo-phone",
        createdAt: now.addingTimeInterval(-4 * 60),
        expiresAt: now.addingTimeInterval(11 * 60),
        updatedAt: now.addingTimeInterval(-4 * 60)
      ),
      MobileCommandRecord(
        id: "command-rerun-checks",
        stationID: station.id,
        kind: .pullRequestRerunChecks,
        risk: .low,
        status: .running,
        title: "Rerun flaky UI check",
        confirmationText: "Rerun failed UI check on PR #812.",
        target: reviewTarget,
        actorDeviceID: "device-demo-phone",
        createdAt: now.addingTimeInterval(-2 * 60),
        expiresAt: now.addingTimeInterval(8 * 60),
        updatedAt: now.addingTimeInterval(-40)
      ),
      MobileCommandRecord(
        id: "command-failed-merge",
        stationID: station.id,
        kind: .pullRequestMerge,
        risk: .destructive,
        status: .failed,
        title: "Merge PR #799",
        confirmationText: "Merge PR #799 with squash.",
        auditReason: "User requested release cleanup.",
        target: MobileCommandTarget(
          stationID: station.id,
          reviewID: "review-799",
          targetRevision: 41
        ),
        actorDeviceID: "device-demo-watch",
        createdAt: now.addingTimeInterval(-24 * 60),
        expiresAt: now.addingTimeInterval(-9 * 60),
        updatedAt: now.addingTimeInterval(-9 * 60),
        receipt: MobileCommandReceipt(
          commandID: "command-failed-merge",
          stationID: station.id,
          status: .failed,
          message: "Fresh-state check rejected revision 41.",
          receivedAt: now.addingTimeInterval(-23 * 60),
          completedAt: now.addingTimeInterval(-9 * 60),
          executionRevision: 42
        )
      ),
    ]

    return MobileMirrorSnapshot(
      revision: 42,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(7 * 24 * 60 * 60),
      stations: [station, laptop],
      attention: attention,
      sessions: sessions,
      reviews: reviews,
      commands: commands,
      trustedDevices: [
        MobileDeviceDescriptor(
          id: "device-demo-phone",
          displayName: "Bart's iPhone",
          publicKeyFingerprint: "7B:61:0F:33",
          pairedAt: now.addingTimeInterval(-3 * 24 * 60 * 60),
          lastCommandAt: now.addingTimeInterval(-40)
        ),
        MobileDeviceDescriptor(
          id: "device-demo-watch",
          displayName: "Bart's Watch",
          publicKeyFingerprint: "91:12:AA:C0",
          pairedAt: now.addingTimeInterval(-2 * 24 * 60 * 60),
          lastCommandAt: now.addingTimeInterval(-9 * 60)
        ),
      ]
    )
  }
}
