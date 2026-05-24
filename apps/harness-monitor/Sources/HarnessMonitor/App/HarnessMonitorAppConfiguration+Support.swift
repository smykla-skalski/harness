import Foundation
import HarnessMonitorKit
import SwiftData

enum HarnessMonitorUITestWindowDefaults {
  private static let mainWindowWidthKey = "HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH"
  private static let mainWindowHeightKey = "HARNESS_MONITOR_UI_MAIN_WINDOW_HEIGHT"
  private static let standardMainWindowSize = CGSize(width: 1640, height: 980)

  static func mainWindowSize(environment: HarnessMonitorEnvironment, isUITesting: Bool) -> CGSize {
    guard isUITesting else {
      return standardMainWindowSize
    }

    let width = clampedDimension(
      rawValue: environment.values[mainWindowWidthKey],
      fallback: standardMainWindowSize.width
    )
    let height = clampedDimension(
      rawValue: environment.values[mainWindowHeightKey],
      fallback: standardMainWindowSize.height
    )

    return CGSize(width: width, height: height)
  }

  private static func clampedDimension(rawValue: String?, fallback: CGFloat) -> CGFloat {
    guard
      let rawValue,
      let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
      value.isFinite
    else {
      return fallback
    }

    return CGFloat(max(value, 640))
  }
}

struct HarnessMonitorPersistenceSetup {
  let container: ModelContainer?
  let error: String?

  static func resolve(
    environment: HarnessMonitorEnvironment,
    launchMode: HarnessMonitorLaunchMode
  ) -> Self {
    if environment.values["HARNESS_MONITOR_FORCE_PERSISTENCE_FAILURE"] == "1" {
      return Self(
        container: nil,
        error: persistenceUnavailableMessage(details: "Forced failure for testing")
      )
    }

    do {
      let container =
        switch launchMode {
        case .live:
          try HarnessMonitorModelContainer.live(using: environment)
        case .preview, .empty:
          try HarnessMonitorModelContainer.preview()
        }

      return Self(container: container, error: nil)
    } catch {
      return Self(
        container: nil,
        error: persistenceUnavailableMessage(details: error.localizedDescription)
      )
    }
  }

  private static func persistenceUnavailableMessage(details: String) -> String {
    """
    Local persistence is unavailable. Harness Monitor will keep running, but bookmarks,
    notes, and search history are disabled. \(details)
    """
  }
}

extension HarnessMonitorAppConfiguration {
  static func uiTestBoolOverride(from rawValue: String?) -> Bool? {
    guard let rawValue else {
      return nil
    }

    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on":
      return true
    case "0", "false", "no", "off":
      return false
    default:
      return nil
    }
  }

  static func applyVoiceUITestDefaults(environment: HarnessMonitorEnvironment) {
    let localeIdentifier = voiceStringOverride(
      environment.values[HarnessMonitorVoiceSettingsDefaults.uiTestLocaleIdentifierOverrideKey],
      fallback: HarnessMonitorVoiceSettings.uiTestDefaultLocaleIdentifier
    )
    let transcriptInsertionMode =
      HarnessMonitorVoiceTranscriptInsertionMode(
        rawValue: environment.values[
          HarnessMonitorVoiceSettingsDefaults.uiTestTranscriptInsertionModeOverrideKey
        ] ?? ""
      ) ?? .manualConfirm
    let localDaemonSinkEnabled =
      uiTestBoolOverride(
        from: environment.values[
          HarnessMonitorVoiceSettingsDefaults.uiTestLocalDaemonSinkEnabledOverrideKey
        ]
      ) ?? true
    let agentBridgeSinkEnabled =
      uiTestBoolOverride(
        from: environment.values[
          HarnessMonitorVoiceSettingsDefaults.uiTestAgentBridgeSinkEnabledOverrideKey
        ]
      ) ?? true
    let remoteProcessorSinkEnabled =
      uiTestBoolOverride(
        from: environment.values[
          HarnessMonitorVoiceSettingsDefaults.uiTestRemoteProcessorEnabledOverrideKey
        ]
      ) ?? false
    let remoteProcessorURL = voiceStringOverride(
      environment.values[
        HarnessMonitorVoiceSettingsDefaults.uiTestRemoteProcessorURLOverrideKey
      ],
      fallback: ""
    )
    let deliversAudioChunks =
      uiTestBoolOverride(
        from: environment.values[
          HarnessMonitorVoiceSettingsDefaults.uiTestDeliversAudioChunksOverrideKey
        ]
      ) ?? true
    let pendingAudioChunkLimit = HarnessMonitorVoiceSettings.normalizedPendingAudioChunkLimit(
      uiTestIntOverride(
        from: environment.values[
          HarnessMonitorVoiceSettingsDefaults.uiTestPendingAudioChunkLimitOverrideKey
        ]
      ) ?? HarnessMonitorVoiceSettings.defaultPendingAudioChunkLimit
    )
    let pendingTranscriptSegmentLimit =
      HarnessMonitorVoiceSettings.normalizedPendingTranscriptSegmentLimit(
        uiTestIntOverride(
          from: environment.values[
            HarnessMonitorVoiceSettingsDefaults.uiTestPendingTranscriptLimitOverrideKey
          ]
        ) ?? HarnessMonitorVoiceSettings.defaultPendingTranscriptSegmentLimit
      )

    applyVoiceDefaultPairs([
      (localeIdentifier, HarnessMonitorVoiceSettingsDefaults.localeIdentifierKey),
      (localDaemonSinkEnabled, HarnessMonitorVoiceSettingsDefaults.localDaemonSinkEnabledKey),
      (agentBridgeSinkEnabled, HarnessMonitorVoiceSettingsDefaults.agentBridgeSinkEnabledKey),
      (
        remoteProcessorSinkEnabled,
        HarnessMonitorVoiceSettingsDefaults.remoteProcessorSinkEnabledKey
      ),
      (remoteProcessorURL, HarnessMonitorVoiceSettingsDefaults.remoteProcessorURLKey),
      (
        transcriptInsertionMode.rawValue,
        HarnessMonitorVoiceSettingsDefaults.transcriptInsertionModeKey
      ),
      (deliversAudioChunks, HarnessMonitorVoiceSettingsDefaults.deliversAudioChunksKey),
      (pendingAudioChunkLimit, HarnessMonitorVoiceSettingsDefaults.pendingAudioChunkLimitKey),
      (
        pendingTranscriptSegmentLimit,
        HarnessMonitorVoiceSettingsDefaults.pendingTranscriptSegmentLimitKey
      ),
    ])
  }

  static func applyVoiceDefaultPairs(_ pairs: [(Any, String)]) {
    for (value, key) in pairs {
      UserDefaults.standard.set(value, forKey: key)
    }
  }

  static func uiTestIntOverride(from rawValue: String?) -> Int? {
    guard let rawValue else {
      return nil
    }
    return Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static func voiceStringOverride(_ rawValue: String?, fallback: String) -> String {
    guard let rawValue else {
      return fallback
    }

    let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedValue.isEmpty ? fallback : trimmedValue
  }
}
