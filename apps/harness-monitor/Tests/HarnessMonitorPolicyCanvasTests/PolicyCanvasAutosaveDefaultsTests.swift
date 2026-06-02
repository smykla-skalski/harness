import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// The Settings > Policies autosave picker is backed by these defaults. They
/// pin the preset set, the Off sentinel, the seconds -> milliseconds bridge the
/// view model consumes, and the agreement between the settings default and the
/// view model's fresh-install window.
@Suite("Policy canvas autosave defaults")
@MainActor
struct PolicyCanvasAutosaveDefaultsTests {
  @Test("fresh-install default is 2 seconds")
  func defaultIsTwoSeconds() {
    #expect(PolicyCanvasAutosaveDefaults.defaultDebounceSeconds == 2)
  }

  @Test("presets are Off and the common windows")
  func presetsCoverOffAndCommonWindows() {
    #expect(PolicyCanvasAutosaveDefaults.presetSeconds == [0, 2, 5, 10, 30])
    #expect(
      PolicyCanvasAutosaveDefaults.presetSeconds.contains(PolicyCanvasAutosaveDefaults.offSeconds)
    )
  }

  @Test("Off is encoded as zero")
  func offIsZero() {
    #expect(PolicyCanvasAutosaveDefaults.offSeconds == 0)
  }

  @Test("label reads Off for zero and seconds otherwise")
  func labelMatchesPreset() {
    #expect(PolicyCanvasAutosaveDefaults.label(forSeconds: 0) == "Off")
    #expect(PolicyCanvasAutosaveDefaults.label(forSeconds: 10) == "10s")
    #expect(PolicyCanvasAutosaveDefaults.label(forSeconds: 60) == "60s")
  }

  @Test("seconds convert to the view-model millisecond window")
  func millisecondsConversion() {
    #expect(PolicyCanvasAutosaveDefaults.milliseconds(forSeconds: 10) == 10_000)
    #expect(PolicyCanvasAutosaveDefaults.milliseconds(forSeconds: 5) == 5_000)
    #expect(PolicyCanvasAutosaveDefaults.milliseconds(forSeconds: 60) == 60_000)
  }

  @Test("Off converts to a zero millisecond window")
  func offConvertsToZeroMilliseconds() {
    let off = PolicyCanvasAutosaveDefaults.offSeconds
    #expect(PolicyCanvasAutosaveDefaults.milliseconds(forSeconds: off) == 0)
  }

  @Test("the settings default agrees with the view-model default window")
  func defaultMatchesViewModelDefault() {
    // A fresh install must show a settings window the view model actually uses,
    // or the picker would advertise a debounce that differs from reality.
    let defaultMilliseconds = PolicyCanvasAutosaveDefaults.milliseconds(
      forSeconds: PolicyCanvasAutosaveDefaults.defaultDebounceSeconds
    )
    #expect(defaultMilliseconds == PolicyCanvasViewModel.defaultAutosaveDebounceMilliseconds)
  }

  @Test("the debounce seconds round-trip through UserDefaults")
  func userDefaultsRoundTrip() {
    let suiteName = "test.policyCanvas.autosaveDefaults"
    let key = PolicyCanvasAutosaveDefaults.debounceSecondsKey
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    defaults.set(30, forKey: key)
    #expect(defaults.integer(forKey: key) == 30)

    defaults.set(PolicyCanvasAutosaveDefaults.offSeconds, forKey: key)
    #expect(defaults.integer(forKey: key) == 0)

    defaults.removePersistentDomain(forName: suiteName)
  }
}
