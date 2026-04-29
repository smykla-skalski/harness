import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("ACP runtime presentation helpers")
struct AcpRuntimeViewTests {
  @Test("Scene storage key uses a stable daemon agent identifier slug")
  func sceneStorageKeyUsesStableAgentIdentifier() {
    #expect(
      AcpRuntimeDisclosure.sceneStorageKey(agentID: "Worker_Codex/1")
        == "harness.agents.runtime-disclosure.worker-codex-1"
    )
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
}
