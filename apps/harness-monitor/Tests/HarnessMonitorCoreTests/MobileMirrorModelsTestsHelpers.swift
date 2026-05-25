import Foundation
import HarnessMonitorCore

func mobileLiveActivityCommand(
  id: String,
  stationID: String,
  status: MobileCommandStatus,
  risk: MobileCommandRisk = .low,
  updatedAt: Date,
  expiresAt: Date? = nil
) -> MobileCommandRecord {
  MobileCommandRecord(
    id: id,
    stationID: stationID,
    kind: .refresh,
    risk: risk,
    status: status,
    title: "Refresh",
    confirmationText: "Refresh station.",
    target: MobileCommandTarget(stationID: stationID, targetRevision: 3),
    actorDeviceID: "phone",
    createdAt: updatedAt.addingTimeInterval(-30),
    expiresAt: expiresAt ?? updatedAt.addingTimeInterval(15 * 60),
    updatedAt: updatedAt
  )
}

func mobileStation(
  _ id: String,
  name: String,
  defaultStation: Bool,
  now: Date
) -> MobileStationSummary {
  MobileStationSummary(
    id: id,
    displayName: name,
    state: .online,
    lastSeenAt: now,
    activeSessionCount: 1,
    needsYouCount: 1,
    commandQueueCount: 1,
    defaultStation: defaultStation
  )
}

func mobileAttention(
  _ id: String,
  stationID: String,
  now: Date
) -> MobileAttentionItem {
  MobileAttentionItem(
    id: id,
    stationID: stationID,
    kind: .taskBoard,
    severity: .warning,
    title: id,
    subtitle: stationID,
    updatedAt: now
  )
}

func mobileSession(
  _ id: String,
  stationID: String,
  now: Date
) -> MobileSessionSummary {
  MobileSessionSummary(
    id: id,
    stationID: stationID,
    projectName: "Harness",
    title: id,
    branch: "main",
    status: "running",
    activeAgentCount: 1,
    blockedAgentCount: 0,
    lastActivityAt: now,
    summary: stationID
  )
}

func mobileReview(
  _ id: String,
  stationID: String,
  now: Date
) -> MobileReviewSummary {
  MobileReviewSummary(
    id: id,
    stationID: stationID,
    repository: "harness",
    number: 1,
    title: id,
    author: "bart",
    state: "open",
    checksSummary: "pending",
    needsYou: true,
    updatedAt: now
  )
}

func mobileTaskBoardItem(
  _ id: String,
  stationID: String,
  now: Date
) -> MobileTaskBoardSummary {
  MobileTaskBoardSummary(
    id: id,
    stationID: stationID,
    title: id,
    bodyPreview: stationID,
    status: "ready",
    statusTitle: "Ready",
    priority: "normal",
    priorityTitle: "Normal",
    agentMode: "codex",
    needsYou: true,
    updatedAt: now
  )
}

func mobileCommand(
  _ id: String,
  stationID: String,
  now: Date
) -> MobileCommandRecord {
  MobileCommandRecord(
    id: id,
    stationID: stationID,
    kind: .refresh,
    risk: .low,
    status: .queued,
    title: id,
    confirmationText: "Refresh.",
    target: MobileCommandTarget(stationID: stationID, targetRevision: 1),
    actorDeviceID: "phone",
    createdAt: now,
    expiresAt: now.addingTimeInterval(60),
    updatedAt: now
  )
}
