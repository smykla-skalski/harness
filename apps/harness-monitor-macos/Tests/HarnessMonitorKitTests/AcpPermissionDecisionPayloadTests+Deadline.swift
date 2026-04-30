import Foundation
import Testing

@testable import HarnessMonitorKit

extension AcpPermissionDecisionPayloadTests {
  @Test("ACP deadlines show a live countdown while traffic is fresh")
  func deadlineStatusShowsCountdown() {
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(expiresAt: isoString(now.addingTimeInterval(61))),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )

    let status = payload.deadlineStatus(now: now, lastMessageAt: now)

    #expect(status?.phase == .pending)
    #expect(status?.label == "expires in 1:01")
    #expect(status?.symbolName == "clock")
    #expect(status?.accessibilityValue == "expires in 1 minute 1 second")
  }

  @Test("ACP deadlines switch to expiring soon with a non-colour cue")
  func deadlineStatusShowsExpiringSoonCue() {
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(expiresAt: isoString(now.addingTimeInterval(29))),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )

    let status = payload.deadlineStatus(now: now, lastMessageAt: now)

    #expect(status?.phase == .expiring)
    #expect(status?.label == "expiring soon — 0:29")
    #expect(status?.symbolName == "clock.badge.exclamationmark")
    #expect(status?.accessibilityValue == "expiring soon, 29 seconds remaining")
  }

  @Test("ACP deadlines become expired after the daemon deadline when traffic is fresh")
  func deadlineStatusShowsExpiredState() {
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(expiresAt: isoString(now.addingTimeInterval(-1))),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )

    let status = payload.deadlineStatus(now: now, lastMessageAt: now)

    #expect(status?.phase == .expired)
    #expect(status?.label == "expired")
    #expect(status?.accessibilityValue == "expired")
  }

  @Test("ACP deadlines stay expired even when daemon traffic is stale")
  func deadlineStatusKeepsExpiredStateWhenTrafficIsStale() {
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(expiresAt: isoString(now.addingTimeInterval(-1))),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )

    let status = payload.deadlineStatus(
      now: now,
      lastMessageAt: now.addingTimeInterval(-31)
    )

    #expect(status?.phase == .expired)
    #expect(status?.label == "expired")
    #expect(status?.accessibilityValue == "expired")
  }

  @Test("ACP deadlines fall back to expires soon after 30 seconds without daemon traffic")
  func deadlineStatusUsesClockSkewTolerance() {
    let now = Date(timeIntervalSince1970: 1_000)
    let payload = AcpPermissionDecisionPayload.make(
      batch: makeBatch(expiresAt: isoString(now.addingTimeInterval(20))),
      agentID: "worker-codex",
      agentName: "Worker Codex"
    )

    let staleMessageAt = now.addingTimeInterval(-31)
    let status = payload.deadlineStatus(now: now, lastMessageAt: staleMessageAt)

    #expect(status?.phase == .stale)
    #expect(status?.label == "expires soon")
    #expect(status?.symbolName == "clock.badge.exclamationmark")
    #expect(status?.accessibilityValue == "expires soon, daemon status stale")
  }

  private func isoString(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
