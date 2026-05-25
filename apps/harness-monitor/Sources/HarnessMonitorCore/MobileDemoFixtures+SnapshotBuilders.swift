import Foundation

extension MobileDemoFixtures {
  static func demoStations(
    now: Date
  ) -> (station: MobileStationSummary, laptop: MobileStationSummary) {
    let station = MobileStationSummary(
      id: "station-mac-studio",
      displayName: "Mac Studio",
      state: .online,
      lastSeenAt: now.addingTimeInterval(-18),
      activeSessionCount: 3,
      needsYouCount: 2,
      commandQueueCount: 4,
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
    return (station, laptop)
  }

  static func demoTargets(
    stationID: String
  ) -> (permissionTarget: MobileCommandTarget, reviewTarget: MobileCommandTarget) {
    (
      MobileCommandTarget(
        stationID: stationID,
        sessionID: "session-pr-review",
        agentID: "agent-codex-7",
        targetRevision: 42
      ),
      MobileCommandTarget(
        stationID: stationID,
        reviewID: "review-812",
        targetRevision: 42
      )
    )
  }

  static func demoAttentionItems(
    station: MobileStationSummary,
    laptop: MobileStationSummary,
    permissionTarget: MobileCommandTarget,
    reviewTarget: MobileCommandTarget,
    now: Date
  ) -> [MobileAttentionItem] {
    [
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
  }

  static func demoTaskBoardItems(
    station: MobileStationSummary,
    laptop: MobileStationSummary,
    now: Date
  ) -> [MobileTaskBoardSummary] {
    [
      MobileTaskBoardSummary(
        id: "task-16",
        stationID: laptop.id,
        title: "Approve mobile sync plan",
        bodyPreview: "Review the pairing, CloudKit, and Watch command plan before work continues.",
        status: "plan_review",
        statusTitle: "Plan Review",
        priority: "high",
        priorityTitle: "High",
        tags: ["mobile", "watch"],
        projectID: "harness-monitor",
        sessionID: "session-mobile-sync",
        agentMode: "planning",
        needsYou: true,
        updatedAt: now.addingTimeInterval(-8 * 60)
      ),
      MobileTaskBoardSummary(
        id: "task-24",
        stationID: station.id,
        title: "Harden command receipts",
        bodyPreview: "Verify signed command receipts, retry safety, and stale-state validation.",
        status: "in_progress",
        statusTitle: "In Progress",
        priority: "critical",
        priorityTitle: "Critical",
        tags: ["commands", "security"],
        projectID: "harness-monitor",
        sessionID: "session-pr-review",
        workItemID: "work-command-receipts",
        agentMode: "interactive",
        needsYou: false,
        updatedAt: now.addingTimeInterval(-3 * 60)
      ),
    ]
  }

  static func demoCommands(
    station: MobileStationSummary,
    laptop: MobileStationSummary,
    reviewTarget: MobileCommandTarget,
    now: Date
  ) -> [MobileCommandRecord] {
    [
      demoApprovePlanCommand(laptop: laptop, now: now),
      demoApproveReviewCommand(station: station, reviewTarget: reviewTarget, now: now),
      demoRerunChecksCommand(station: station, reviewTarget: reviewTarget, now: now),
      demoFailedMergeCommand(station: station, now: now),
      demoLabelReadyCommand(station: station, reviewTarget: reviewTarget, now: now),
    ]
  }

  static func demoApprovePlanCommand(
    laptop: MobileStationSummary,
    now: Date
  ) -> MobileCommandRecord {
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
    )
  }

  static func demoApproveReviewCommand(
    station: MobileStationSummary,
    reviewTarget: MobileCommandTarget,
    now: Date
  ) -> MobileCommandRecord {
    MobileCommandRecord(
      id: "command-approve-review",
      stationID: station.id,
      kind: .pullRequestApprove,
      risk: .low,
      status: .accepted,
      title: "Approve PR #812",
      confirmationText: "Approve command receipt audit trail.",
      target: reviewTarget,
      actorDeviceID: "device-demo-phone",
      createdAt: now.addingTimeInterval(-3 * 60),
      expiresAt: now.addingTimeInterval(9 * 60),
      updatedAt: now.addingTimeInterval(-80)
    )
  }

  static func demoRerunChecksCommand(
    station: MobileStationSummary,
    reviewTarget: MobileCommandTarget,
    now: Date
  ) -> MobileCommandRecord {
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
    )
  }

  static func demoFailedMergeCommand(
    station: MobileStationSummary,
    now: Date
  ) -> MobileCommandRecord {
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
    )
  }

  static func demoLabelReadyCommand(
    station: MobileStationSummary,
    reviewTarget: MobileCommandTarget,
    now: Date
  ) -> MobileCommandRecord {
    MobileCommandRecord(
      id: "command-label-ready",
      stationID: station.id,
      kind: .pullRequestLabel,
      risk: .low,
      status: .succeeded,
      title: "Label PR #812 ready",
      confirmationText: "Apply ready label to PR #812.",
      target: reviewTarget,
      payload: ["label": "ready"],
      actorDeviceID: "device-demo-phone",
      createdAt: now.addingTimeInterval(-38 * 60),
      expiresAt: now.addingTimeInterval(-26 * 60),
      updatedAt: now.addingTimeInterval(-27 * 60),
      receipt: MobileCommandReceipt(
        commandID: "command-label-ready",
        stationID: station.id,
        status: .succeeded,
        message: "Applied ready label at revision 42.",
        receivedAt: now.addingTimeInterval(-37 * 60),
        completedAt: now.addingTimeInterval(-27 * 60),
        executionRevision: 42
      )
    )
  }

  static func demoTrustedDevices(now: Date) -> [MobileDeviceDescriptor] {
    [
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
  }
}
