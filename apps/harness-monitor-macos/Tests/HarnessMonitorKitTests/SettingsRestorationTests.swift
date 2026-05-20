import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Settings scroll restoration")
struct SettingsRestorationTests {
  @Test("Idle and programmatic animation phases are not user scroll")
  func nonUserPhasesDoNotPersistByThemselves() {
    #expect(!SettingsScrollRestorationPhasePolicy.isUserScroll(.idle))
    #expect(!SettingsScrollRestorationPhasePolicy.isUserScroll(.animating))
  }

  @Test("Direct user scroll phases are user scroll")
  func userScrollPhasesPersist() {
    #expect(SettingsScrollRestorationPhasePolicy.isUserScroll(.tracking))
    #expect(SettingsScrollRestorationPhasePolicy.isUserScroll(.interacting))
    #expect(SettingsScrollRestorationPhasePolicy.isUserScroll(.decelerating))
  }

  @Test("Idle zero geometry does not overwrite a stored scroll offset")
  func idleZeroGeometryDoesNotOverwriteStoredOffset() {
    #expect(
      !SettingsScrollPersistencePolicy.shouldPersist(
        0,
        previousOffset: 96,
        force: false,
        allowsZero: false
      )
    )
  }

  @Test("Confirmed user scroll can persist top")
  func confirmedUserScrollCanPersistTop() {
    #expect(
      SettingsScrollPersistencePolicy.shouldPersist(
        0,
        previousOffset: 96,
        force: true,
        allowsZero: true
      )
    )
  }

  @Test("Nonzero movement uses a coarse persistence threshold")
  func nonzeroMovementUsesPersistenceThreshold() {
    #expect(!SettingsScrollPersistencePolicy.hasMeaningfulMovement(from: 96, to: 116))
    #expect(SettingsScrollPersistencePolicy.hasMeaningfulMovement(from: 96, to: 140))
  }

  @Test("Restore target clamps to available content")
  func restoreTargetClampsToAvailableContent() {
    #expect(
      SettingsScrollPersistencePolicy.restorationTargetOffset(
        storedOffset: 384,
        maxOffset: 120
      ) == 120
    )
  }
}
