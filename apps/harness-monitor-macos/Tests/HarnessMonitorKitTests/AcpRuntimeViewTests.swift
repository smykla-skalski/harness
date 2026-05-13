import Foundation
import HarnessMonitorKit
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("ACP runtime presentation helpers")
struct AcpRuntimeViewTests {
  @Test("Scene storage key keeps a non-lossy session and agent identifier")
  func sceneStorageKeyUsesStableAgentIdentifier() {
    let key = AcpRuntimeDisclosure.sceneStorageKey(
      sessionID: "sess-harness/main",
      acpID: "acp-1",
      agentID: "Worker/1"
    )

    #expect(
      key
        == AcpRuntimeDisclosure.sceneStorageKey(
          sessionID: "sess-harness/main",
          acpID: "acp-1",
          agentID: "Worker/1"
        )
    )
    #expect(
      key
        != AcpRuntimeDisclosure.sceneStorageKey(
          sessionID: "sess-harness/main",
          acpID: "acp-1",
          agentID: "Worker_2f1"
        )
    )
  }

  @Test("Scene storage key keeps restarted ACP runtimes isolated")
  func sceneStorageKeyIncludesAcpRuntimeIdentifier() {
    let first = AcpRuntimeDisclosure.sceneStorageKey(
      sessionID: "sess-harness/main",
      acpID: "acp-1",
      agentID: "Worker/1"
    )
    let restarted = AcpRuntimeDisclosure.sceneStorageKey(
      sessionID: "sess-harness/main",
      acpID: "acp-2",
      agentID: "Worker/1"
    )

    #expect(first != restarted)
  }

  @Test("Runtime identity id keeps session, ACP, and agent components lossless")
  func runtimeIdentityIDUsesLosslessEncoding() {
    let left = AcpRuntimeIdentity(
      sessionID: "sess|alpha",
      acpID: "acp",
      agentID: "worker"
    )
    let right = AcpRuntimeIdentity(
      sessionID: "sess",
      acpID: "alpha|acp",
      agentID: "worker"
    )

    #expect(left.id != right.id)
  }

  @Test("Disclosure motion policy disables animation for reduce motion")
  func disclosureMotionPolicyRespectsReduceMotion() {
    #expect(AcpRuntimeDisclosureMotionPolicy.animation(reduceMotion: true) == nil)
    #expect(AcpRuntimeDisclosureMotionPolicy.animation(reduceMotion: false) != nil)
  }

  @Test("Watchdog announcement policy debounces polite and assertive repeats")
  func watchdogAnnouncementPolicyDebouncesRepeats() {
    let now = Date(timeIntervalSince1970: 100)
    let polite = AcpRuntimeWatchdogAnnouncement(state: "active", announcedAt: now)
    let assertive = AcpRuntimeWatchdogAnnouncement(state: "fired", announcedAt: now)

    #expect(
      AcpRuntimeWatchdogAnnouncementPolicy.shouldAnnounce(
        state: "active",
        lastAnnouncement: polite,
        now: now.addingTimeInterval(29)
      ) == false
    )
    #expect(
      AcpRuntimeWatchdogAnnouncementPolicy.shouldAnnounce(
        state: "active",
        lastAnnouncement: polite,
        now: now.addingTimeInterval(31)
      ) == true
    )
    #expect(
      AcpRuntimeWatchdogAnnouncementPolicy.shouldAnnounce(
        state: "fired",
        lastAnnouncement: assertive,
        now: now.addingTimeInterval(59)
      ) == false
    )
    #expect(
      AcpRuntimeWatchdogAnnouncementPolicy.shouldAnnounce(
        state: "fired",
        lastAnnouncement: assertive,
        now: now.addingTimeInterval(61)
      ) == true
    )
  }

  @Test("Watchdog accessibility live-region policy is assertive only for fired state")
  func watchdogAccessibilityLiveRegionPolicy() {
    #expect(AcpRuntimeWatchdogAnnouncementPolicy.liveRegion(for: "active") == "polite")
    #expect(AcpRuntimeWatchdogAnnouncementPolicy.liveRegion(for: " warning ") == "polite")
    #expect(AcpRuntimeWatchdogAnnouncementPolicy.liveRegion(for: "fired") == "assertive")
  }

  @Test("Watchdog announcement state resets when runtime identity changes")
  func watchdogAnnouncementCoordinatorSeedsOnRuntimeIdentityChange() {
    let now = Date(timeIntervalSince1970: 200)
    let effect = AcpRuntimeWatchdogAnnouncementCoordinator.effect(
      from: AcpRuntimeWatchdogSignal(runtimeID: "runtime-a", state: "active"),
      to: AcpRuntimeWatchdogSignal(runtimeID: "runtime-b", state: "active"),
      lastAnnouncement: AcpRuntimeWatchdogAnnouncement(
        state: "active",
        announcedAt: now.addingTimeInterval(-10)
      ),
      agentName: "Worker",
      now: now
    )

    #expect(
      effect
        == .seed(
          AcpRuntimeWatchdogAnnouncement(state: "active", announcedAt: now)
        )
    )
  }

  @Test("Watchdog announcement state announces same-runtime watchdog changes")
  func watchdogAnnouncementCoordinatorAnnouncesWithinRuntimeIdentity() {
    let now = Date(timeIntervalSince1970: 300)
    let effect = AcpRuntimeWatchdogAnnouncementCoordinator.effect(
      from: AcpRuntimeWatchdogSignal(runtimeID: "runtime-a", state: "active"),
      to: AcpRuntimeWatchdogSignal(runtimeID: "runtime-a", state: "fired"),
      lastAnnouncement: AcpRuntimeWatchdogAnnouncement(
        state: "active",
        announcedAt: now.addingTimeInterval(-10)
      ),
      agentName: "Worker",
      now: now
    )

    #expect(
      effect
        == .announce(
          message: "Worker watchdog fired",
          announcement: AcpRuntimeWatchdogAnnouncement(
            state: "fired",
            announcedAt: now
          )
        )
    )
  }

  @Test("Prompt deadline presentation derives countdown from supplied clock tick")
  func promptDeadlinePresentationUsesReferenceDate() throws {
    let deadline = Date(timeIntervalSince1970: 125)
    let normal = try #require(
      AcpRuntimeDeadlinePresentation.presentation(
        deadline: deadline,
        now: Date(timeIntervalSince1970: 61)
      )
    )
    #expect(normal.countdownLabel == "1:04")
    #expect(normal.accessibilityLabel == "64 seconds remaining")
    #expect(normal.isUrgent == false)

    let urgent = try #require(
      AcpRuntimeDeadlinePresentation.presentation(
        deadline: deadline,
        now: Date(timeIntervalSince1970: 116)
      )
    )
    #expect(urgent.countdownLabel == "0:09")
    #expect(urgent.accessibilityLabel == "9 seconds remaining")
    #expect(urgent.isUrgent)
    #expect(
      AcpRuntimeDeadlinePresentation.presentation(
        deadline: deadline,
        now: Date(timeIntervalSince1970: 125)
      ) == nil
    )
  }

  @Test("Runtime strip keeps deadline clock state out of the strip body")
  func runtimeStripKeepsDeadlineClockStateOutOfTheStripBody() throws {
    let stripSource = try previewableSourceFile(named: "Views/Acp/AcpRuntimeStatusStrip.swift")
    let supportSource = try previewableSourceFile(
      named: "Views/Acp/AcpRuntimeStatusStripSupport.swift"
    )

    #expect(!stripSource.contains("@State private var deadlineNow"))
    #expect(stripSource.contains("@State private var deadlineClock"))
    let deadlineClockRunCall =
      "await deadlineClock.run(store: store, deadline: promptDeadlineDate)"
    #expect(stripSource.contains(deadlineClockRunCall))
    #expect(stripSource.contains("AcpRuntimeStatusEdgeAccentView("))
    #expect(
      stripSource.contains(
        "AcpRuntimeDeadlineChip(\n        deadlineClock: deadlineClock,\n        deadline: promptDeadlineDate"
      )
    )
    #expect(!stripSource.contains("runDeadlineClockIfNeeded"))
    #expect(supportSource.contains("final class AcpRuntimeDeadlineClockState"))
    #expect(supportSource.contains("struct AcpRuntimeStatusEdgeAccentView: View"))
  }

  private func previewableSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
