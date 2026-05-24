import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor voice settings")
struct HarnessMonitorVoiceSettingsTests {
  @Test("Stored voice settings decode the persisted configuration")
  func storedVoiceSettingsDecodeThePersistedConfiguration() {
    let (defaults, suiteName) = makeIsolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set("pl_PL", forKey: HarnessMonitorVoiceSettingsDefaults.localeIdentifierKey)
    defaults.set(false, forKey: HarnessMonitorVoiceSettingsDefaults.localDaemonSinkEnabledKey)
    defaults.set(true, forKey: HarnessMonitorVoiceSettingsDefaults.agentBridgeSinkEnabledKey)
    defaults.set(true, forKey: HarnessMonitorVoiceSettingsDefaults.remoteProcessorSinkEnabledKey)
    defaults.set(
      "https://processor.example/voice",
      forKey: HarnessMonitorVoiceSettingsDefaults.remoteProcessorURLKey
    )
    defaults.set(
      HarnessMonitorVoiceTranscriptInsertionMode.autoInsert.rawValue,
      forKey: HarnessMonitorVoiceSettingsDefaults.transcriptInsertionModeKey
    )
    defaults.set(false, forKey: HarnessMonitorVoiceSettingsDefaults.deliversAudioChunksKey)
    defaults.set(11, forKey: HarnessMonitorVoiceSettingsDefaults.pendingAudioChunkLimitKey)
    defaults.set(
      9,
      forKey: HarnessMonitorVoiceSettingsDefaults.pendingTranscriptSegmentLimitKey
    )

    let settings = HarnessMonitorVoiceSettings.stored(defaults: defaults)

    #expect(settings.effectiveLocaleIdentifier == "pl_PL")
    #expect(settings.requestedSinks == [.agentBridge, .remoteProcessor])
    #expect(settings.remoteProcessorURL?.absoluteString == "https://processor.example/voice")
    #expect(settings.shouldAutoInsertTranscript)
    #expect(!settings.deliversAudioChunks)
    #expect(settings.pendingAudioChunkLimit == 11)
    #expect(settings.pendingTranscriptSegmentLimit == 9)
  }

  @Test("Voice settings fall back to the local daemon when all sinks are disabled")
  func voiceSettingsFallBackToTheLocalDaemonWhenAllSinksAreDisabled() {
    let settings = HarnessMonitorVoiceSettings(
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

    #expect(settings.requestedSinks == [.localDaemon])
  }

  @Test("Remote processor endpoints must be full HTTPS URLs")
  func remoteProcessorEndpointsMustBeFullHTTPSURLs() {
    let invalidSettings = HarnessMonitorVoiceSettings(
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
    let validSettings = HarnessMonitorVoiceSettings(
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

    #expect(invalidSettings.remoteProcessorURL == nil)
    #expect(
      validSettings.remoteProcessorURL?.absoluteString == "https://processor.example/voice")
  }

  @Test("Pending limits clamp to the supported range")
  func pendingLimitsClampToTheSupportedRange() {
    let settings = HarnessMonitorVoiceSettings(
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
      settings.pendingAudioChunkLimit
        == HarnessMonitorVoiceSettings.maxPendingAudioChunkLimit
    )
    #expect(
      settings.pendingTranscriptSegmentLimit
        == HarnessMonitorVoiceSettings.minPendingTranscriptSegmentLimit
    )
  }

  @Test("Locale options keep the selected locale first")
  func localeOptionsKeepTheSelectedLocaleFirst() {
    let options = HarnessMonitorVoiceSettings.localeOptions(
      selectedLocaleIdentifier: "ja_JP",
      currentLocale: Locale(identifier: "en_US")
    )

    #expect(options.first?.identifier == "ja_JP")
    #expect(options.contains(where: { $0.identifier == "en_US" }))
  }

  private func makeIsolatedDefaults() -> (UserDefaults, String) {
    let suiteName = "HarnessMonitorVoiceSettingsTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      preconditionFailure("UserDefaults(suiteName:) returned nil for suite: \(suiteName)")
    }
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
  }
}
