import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor voice preferences")
struct HarnessMonitorVoicePreferencesTests {
  @Test("Stored voice preferences decode the persisted configuration")
  func storedVoicePreferencesDecodeThePersistedConfiguration() {
    let (defaults, suiteName) = makeIsolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set("pl_PL", forKey: HarnessMonitorVoicePreferencesDefaults.localeIdentifierKey)
    defaults.set(false, forKey: HarnessMonitorVoicePreferencesDefaults.localDaemonSinkEnabledKey)
    defaults.set(true, forKey: HarnessMonitorVoicePreferencesDefaults.agentBridgeSinkEnabledKey)
    defaults.set(true, forKey: HarnessMonitorVoicePreferencesDefaults.remoteProcessorSinkEnabledKey)
    defaults.set(
      "https://processor.example/voice",
      forKey: HarnessMonitorVoicePreferencesDefaults.remoteProcessorURLKey
    )
    defaults.set(
      HarnessMonitorVoiceTranscriptInsertionMode.autoInsert.rawValue,
      forKey: HarnessMonitorVoicePreferencesDefaults.transcriptInsertionModeKey
    )
    defaults.set(false, forKey: HarnessMonitorVoicePreferencesDefaults.deliversAudioChunksKey)
    defaults.set(11, forKey: HarnessMonitorVoicePreferencesDefaults.pendingAudioChunkLimitKey)
    defaults.set(
      9,
      forKey: HarnessMonitorVoicePreferencesDefaults.pendingTranscriptSegmentLimitKey
    )

    let preferences = HarnessMonitorVoicePreferences.stored(defaults: defaults)

    #expect(preferences.effectiveLocaleIdentifier == "pl_PL")
    #expect(preferences.requestedSinks == [.agentBridge, .remoteProcessor])
    #expect(preferences.remoteProcessorURL?.absoluteString == "https://processor.example/voice")
    #expect(preferences.shouldAutoInsertTranscript)
    #expect(!preferences.deliversAudioChunks)
    #expect(preferences.pendingAudioChunkLimit == 11)
    #expect(preferences.pendingTranscriptSegmentLimit == 9)
  }

  @Test("Voice preferences fall back to the local daemon when all sinks are disabled")
  func voicePreferencesFallBackToTheLocalDaemonWhenAllSinksAreDisabled() {
    let preferences = HarnessMonitorVoicePreferences(
      localeIdentifier: "en_US",
      localDaemonSinkEnabled: false,
      agentBridgeSinkEnabled: false,
      remoteProcessorSinkEnabled: false,
      remoteProcessorURLText: "",
      transcriptInsertionModeRawValue: HarnessMonitorVoiceTranscriptInsertionMode.manualConfirm
        .rawValue,
      deliversAudioChunks: true,
      pendingAudioChunkLimit: 24,
      pendingTranscriptSegmentLimit: 16
    )

    #expect(preferences.requestedSinks == [.localDaemon])
  }

  @Test("Remote processor endpoints must be full HTTPS URLs")
  func remoteProcessorEndpointsMustBeFullHTTPSURLs() {
    let invalidPreferences = HarnessMonitorVoicePreferences(
      localeIdentifier: "en_US",
      localDaemonSinkEnabled: true,
      agentBridgeSinkEnabled: true,
      remoteProcessorSinkEnabled: true,
      remoteProcessorURLText: "http://processor.example/voice",
      transcriptInsertionModeRawValue: HarnessMonitorVoiceTranscriptInsertionMode.manualConfirm
        .rawValue,
      deliversAudioChunks: true,
      pendingAudioChunkLimit: 24,
      pendingTranscriptSegmentLimit: 16
    )
    let validPreferences = HarnessMonitorVoicePreferences(
      localeIdentifier: "en_US",
      localDaemonSinkEnabled: true,
      agentBridgeSinkEnabled: true,
      remoteProcessorSinkEnabled: true,
      remoteProcessorURLText: "https://processor.example/voice",
      transcriptInsertionModeRawValue: HarnessMonitorVoiceTranscriptInsertionMode.manualConfirm
        .rawValue,
      deliversAudioChunks: true,
      pendingAudioChunkLimit: 24,
      pendingTranscriptSegmentLimit: 16
    )

    #expect(invalidPreferences.remoteProcessorURL == nil)
    #expect(validPreferences.remoteProcessorURL?.absoluteString == "https://processor.example/voice")
  }

  @Test("Pending limits clamp to the supported range")
  func pendingLimitsClampToTheSupportedRange() {
    let preferences = HarnessMonitorVoicePreferences(
      localeIdentifier: "en_US",
      localDaemonSinkEnabled: true,
      agentBridgeSinkEnabled: true,
      remoteProcessorSinkEnabled: false,
      remoteProcessorURLText: "",
      transcriptInsertionModeRawValue: HarnessMonitorVoiceTranscriptInsertionMode.manualConfirm
        .rawValue,
      deliversAudioChunks: true,
      pendingAudioChunkLimit: 1_000,
      pendingTranscriptSegmentLimit: 1
    )

    #expect(
      preferences.pendingAudioChunkLimit
        == HarnessMonitorVoicePreferences.maxPendingAudioChunkLimit
    )
    #expect(
      preferences.pendingTranscriptSegmentLimit
        == HarnessMonitorVoicePreferences.minPendingTranscriptSegmentLimit
    )
  }

  @Test("Locale options keep the selected locale first")
  func localeOptionsKeepTheSelectedLocaleFirst() {
    let options = HarnessMonitorVoicePreferences.localeOptions(
      selectedLocaleIdentifier: "ja_JP",
      currentLocale: Locale(identifier: "en_US")
    )

    #expect(options.first?.identifier == "ja_JP")
    #expect(options.contains(where: { $0.identifier == "en_US" }))
  }

  private func makeIsolatedDefaults() -> (UserDefaults, String) {
    let suiteName = "HarnessMonitorVoicePreferencesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
  }
}
