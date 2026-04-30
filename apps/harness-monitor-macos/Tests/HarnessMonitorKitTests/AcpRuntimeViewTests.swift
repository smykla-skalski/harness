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
      agentID: "Worker/1"
    )

    #expect(
      key
        == AcpRuntimeDisclosure.sceneStorageKey(
          sessionID: "sess-harness/main",
          agentID: "Worker/1"
        )
    )
    #expect(
      key
        != AcpRuntimeDisclosure.sceneStorageKey(
          sessionID: "sess-harness/main",
          agentID: "Worker_2f1"
        )
    )
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
          announcement: AcpRuntimeWatchdogAnnouncement(state: "fired", announcedAt: now)
        )
    )
  }
}
