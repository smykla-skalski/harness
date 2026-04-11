import Foundation

public enum HarnessMonitorVoicePreferencesDefaults {
  public static let localeIdentifierKey = "harnessVoiceLocaleIdentifier"
  public static let localDaemonSinkEnabledKey = "harnessVoiceLocalDaemonSinkEnabled"
  public static let agentBridgeSinkEnabledKey = "harnessVoiceAgentBridgeSinkEnabled"
  public static let remoteProcessorSinkEnabledKey = "harnessVoiceRemoteProcessorSinkEnabled"
  public static let remoteProcessorURLKey = "harnessVoiceRemoteProcessorURL"
  public static let transcriptInsertionModeKey = "harnessVoiceTranscriptInsertionMode"
  public static let deliversAudioChunksKey = "harnessVoiceDeliversAudioChunks"
  public static let pendingAudioChunkLimitKey = "harnessVoicePendingAudioChunkLimit"
  public static let pendingTranscriptSegmentLimitKey = "harnessVoicePendingTranscriptSegmentLimit"

  public static let uiTestLocaleIdentifierOverrideKey = "HARNESS_MONITOR_VOICE_LOCALE_OVERRIDE"
  public static let uiTestLocalDaemonSinkEnabledOverrideKey =
    "HARNESS_MONITOR_VOICE_LOCAL_DAEMON_ENABLED_OVERRIDE"
  public static let uiTestAgentBridgeSinkEnabledOverrideKey =
    "HARNESS_MONITOR_VOICE_AGENT_BRIDGE_ENABLED_OVERRIDE"
  public static let uiTestRemoteProcessorSinkEnabledOverrideKey =
    "HARNESS_MONITOR_VOICE_REMOTE_PROCESSOR_ENABLED_OVERRIDE"
  public static let uiTestRemoteProcessorURLOverrideKey =
    "HARNESS_MONITOR_VOICE_REMOTE_PROCESSOR_URL_OVERRIDE"
  public static let uiTestTranscriptInsertionModeOverrideKey =
    "HARNESS_MONITOR_VOICE_INSERTION_MODE_OVERRIDE"
  public static let uiTestDeliversAudioChunksOverrideKey =
    "HARNESS_MONITOR_VOICE_DELIVERS_AUDIO_CHUNKS_OVERRIDE"
  public static let uiTestPendingAudioChunkLimitOverrideKey =
    "HARNESS_MONITOR_VOICE_PENDING_AUDIO_LIMIT_OVERRIDE"
  public static let uiTestPendingTranscriptSegmentLimitOverrideKey =
    "HARNESS_MONITOR_VOICE_PENDING_TRANSCRIPT_LIMIT_OVERRIDE"
}

public enum HarnessMonitorVoiceTranscriptInsertionMode: String, CaseIterable, Identifiable, Sendable
{
  case manualConfirm
  case autoInsert

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .manualConfirm:
      "Manual Confirm"
    case .autoInsert:
      "Auto Insert"
    }
  }

  public var detail: String {
    switch self {
    case .manualConfirm:
      "Keep the transcript in the voice popover until you explicitly insert it."
    case .autoInsert:
      "Insert the final transcript into the active field as soon as recording finishes."
    }
  }

  public var requiresConfirmation: Bool {
    self == .manualConfirm
  }
}

public struct HarnessMonitorVoiceLocaleOption: Equatable, Identifiable, Sendable {
  public let identifier: String
  public let title: String
  public let detail: String

  public var id: String { identifier }
}

public enum HarnessMonitorVoiceRemoteProcessorStatus: Equatable, Sendable {
  case disabled
  case valid(URL)
  case invalid
}

public struct HarnessMonitorVoicePreferences: Equatable, Sendable {
  public static let uiTestDefaultLocaleIdentifier = "en_US"
  public static let defaultPendingAudioChunkLimit = 24
  public static let defaultPendingTranscriptSegmentLimit = 16
  public static let minPendingAudioChunkLimit = 4
  public static let maxPendingAudioChunkLimit = 128
  public static let minPendingTranscriptSegmentLimit = 4
  public static let maxPendingTranscriptSegmentLimit = 64

  public let localeIdentifier: String
  public let localDaemonSinkEnabled: Bool
  public let agentBridgeSinkEnabled: Bool
  public let remoteProcessorSinkEnabled: Bool
  public let remoteProcessorURLText: String
  public let transcriptInsertionModeRawValue: String
  public let deliversAudioChunks: Bool
  public let pendingAudioChunkLimit: Int
  public let pendingTranscriptSegmentLimit: Int

  public init(
    localeIdentifier: String,
    localDaemonSinkEnabled: Bool,
    agentBridgeSinkEnabled: Bool,
    remoteProcessorSinkEnabled: Bool,
    remoteProcessorURLText: String,
    transcriptInsertionModeRawValue: String,
    deliversAudioChunks: Bool,
    pendingAudioChunkLimit: Int,
    pendingTranscriptSegmentLimit: Int
  ) {
    self.localeIdentifier = localeIdentifier
    self.localDaemonSinkEnabled = localDaemonSinkEnabled
    self.agentBridgeSinkEnabled = agentBridgeSinkEnabled
    self.remoteProcessorSinkEnabled = remoteProcessorSinkEnabled
    self.remoteProcessorURLText = remoteProcessorURLText
    self.transcriptInsertionModeRawValue = transcriptInsertionModeRawValue
    self.deliversAudioChunks = deliversAudioChunks
    self.pendingAudioChunkLimit = Self.normalizedPendingAudioChunkLimit(pendingAudioChunkLimit)
    self.pendingTranscriptSegmentLimit = Self.normalizedPendingTranscriptSegmentLimit(
      pendingTranscriptSegmentLimit
    )
  }

  public static var defaultLocaleIdentifier: String {
    Locale.current.identifier
  }

  public static var `default`: Self {
    stored()
  }

  public static func registrationDefaults(
    localeIdentifier: String = defaultLocaleIdentifier
  ) -> [String: Any] {
    [
      HarnessMonitorVoicePreferencesDefaults.localeIdentifierKey: localeIdentifier,
      HarnessMonitorVoicePreferencesDefaults.localDaemonSinkEnabledKey: true,
      HarnessMonitorVoicePreferencesDefaults.agentBridgeSinkEnabledKey: true,
      HarnessMonitorVoicePreferencesDefaults.remoteProcessorSinkEnabledKey: false,
      HarnessMonitorVoicePreferencesDefaults.remoteProcessorURLKey: "",
      HarnessMonitorVoicePreferencesDefaults.transcriptInsertionModeKey:
        HarnessMonitorVoiceTranscriptInsertionMode.manualConfirm.rawValue,
      HarnessMonitorVoicePreferencesDefaults.deliversAudioChunksKey: true,
      HarnessMonitorVoicePreferencesDefaults.pendingAudioChunkLimitKey:
        defaultPendingAudioChunkLimit,
      HarnessMonitorVoicePreferencesDefaults.pendingTranscriptSegmentLimitKey:
        defaultPendingTranscriptSegmentLimit,
    ]
  }

  public static func stored(defaults: UserDefaults = .standard) -> Self {
    Self(
      localeIdentifier: defaults.string(forKey: HarnessMonitorVoicePreferencesDefaults.localeIdentifierKey)
        ?? defaultLocaleIdentifier,
      localDaemonSinkEnabled: defaults.object(
        forKey: HarnessMonitorVoicePreferencesDefaults.localDaemonSinkEnabledKey
      ) as? Bool ?? true,
      agentBridgeSinkEnabled: defaults.object(
        forKey: HarnessMonitorVoicePreferencesDefaults.agentBridgeSinkEnabledKey
      ) as? Bool ?? true,
      remoteProcessorSinkEnabled: defaults.object(
        forKey: HarnessMonitorVoicePreferencesDefaults.remoteProcessorSinkEnabledKey
      ) as? Bool ?? false,
      remoteProcessorURLText: defaults.string(
        forKey: HarnessMonitorVoicePreferencesDefaults.remoteProcessorURLKey
      ) ?? "",
      transcriptInsertionModeRawValue: defaults.string(
        forKey: HarnessMonitorVoicePreferencesDefaults.transcriptInsertionModeKey
      ) ?? HarnessMonitorVoiceTranscriptInsertionMode.manualConfirm.rawValue,
      deliversAudioChunks: defaults.object(
        forKey: HarnessMonitorVoicePreferencesDefaults.deliversAudioChunksKey
      ) as? Bool ?? true,
      pendingAudioChunkLimit: defaults.object(
        forKey: HarnessMonitorVoicePreferencesDefaults.pendingAudioChunkLimitKey
      ) as? Int ?? defaultPendingAudioChunkLimit,
      pendingTranscriptSegmentLimit: defaults.object(
        forKey: HarnessMonitorVoicePreferencesDefaults.pendingTranscriptSegmentLimitKey
      ) as? Int ?? defaultPendingTranscriptSegmentLimit
    )
  }

  public var trimmedLocaleIdentifier: String {
    localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var effectiveLocaleIdentifier: String {
    trimmedLocaleIdentifier.isEmpty ? Self.defaultLocaleIdentifier : trimmedLocaleIdentifier
  }

  public var transcriptInsertionMode: HarnessMonitorVoiceTranscriptInsertionMode {
    HarnessMonitorVoiceTranscriptInsertionMode(rawValue: transcriptInsertionModeRawValue)
      ?? .manualConfirm
  }

  public var shouldAutoInsertTranscript: Bool {
    transcriptInsertionMode == .autoInsert
  }

  public var transcriptInsertionSummary: String {
    transcriptInsertionMode.detail
  }

  public var requestedSinks: [VoiceProcessingSink] {
    var sinks: [VoiceProcessingSink] = []
    if localDaemonSinkEnabled {
      sinks.append(.localDaemon)
    }
    if agentBridgeSinkEnabled {
      sinks.append(.agentBridge)
    }
    if remoteProcessorSinkEnabled {
      sinks.append(.remoteProcessor)
    }
    return sinks.isEmpty ? [.localDaemon] : sinks
  }

  public var requestedSinksSummary: String {
    requestedSinks.map(\.title).joined(separator: ", ")
  }

  public var remoteProcessorStatus: HarnessMonitorVoiceRemoteProcessorStatus {
    guard remoteProcessorSinkEnabled else {
      return .disabled
    }

    guard
      let url = URL(string: trimmedRemoteProcessorURLText),
      url.scheme?.lowercased() == "https",
      url.host?.isEmpty == false
    else {
      return .invalid
    }

    return .valid(url)
  }

  public var remoteProcessorURL: URL? {
    guard case .valid(let url) = remoteProcessorStatus else {
      return nil
    }
    return url
  }

  public var trimmedRemoteProcessorURLText: String {
    remoteProcessorURLText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var remoteProcessorSummary: String {
    switch remoteProcessorStatus {
    case .disabled:
      "Disabled"
    case .invalid:
      "Invalid HTTPS endpoint"
    case .valid(let url):
      url.absoluteString
    }
  }

  public var captureConfiguration: VoiceCaptureConfiguration {
    VoiceCaptureConfiguration(
      localeIdentifier: effectiveLocaleIdentifier,
      deliversAudioChunks: deliversAudioChunks
    )
  }

  public var audioChunkDeliverySummary: String {
    deliversAudioChunks
      ? "Audio chunks stream to enabled processing sinks while recording."
      : "Only transcript segments are sent while recording."
  }

  public static func normalizedPendingAudioChunkLimit(_ value: Int) -> Int {
    min(max(value, minPendingAudioChunkLimit), maxPendingAudioChunkLimit)
  }

  public static func normalizedPendingTranscriptSegmentLimit(_ value: Int) -> Int {
    min(max(value, minPendingTranscriptSegmentLimit), maxPendingTranscriptSegmentLimit)
  }

  public static func localeOptions(
    selectedLocaleIdentifier: String,
    currentLocale: Locale = .current
  ) -> [HarnessMonitorVoiceLocaleOption] {
    let prioritizedIdentifiers = [
      selectedLocaleIdentifier,
      currentLocale.identifier,
      Locale.autoupdatingCurrent.identifier,
      "en_US",
      "en_GB",
      "pl_PL",
      "de_DE",
      "fr_FR",
      "es_ES",
      "it_IT",
      "ja_JP",
      "pt_BR",
    ]

    var seenIdentifiers: Set<String> = []
    return prioritizedIdentifiers.compactMap { identifier in
      let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedIdentifier.isEmpty, seenIdentifiers.insert(trimmedIdentifier).inserted else {
        return nil
      }
      return HarnessMonitorVoiceLocaleOption(
        identifier: trimmedIdentifier,
        title: localeDisplayLabel(for: trimmedIdentifier, currentLocale: currentLocale),
        detail: trimmedIdentifier
      )
    }
  }

  public static func localeDisplayName(
    for identifier: String,
    currentLocale: Locale = .current
  ) -> String {
    let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedIdentifier.isEmpty else {
      return defaultLocaleIdentifier
    }
    return currentLocale.localizedString(forIdentifier: trimmedIdentifier) ?? trimmedIdentifier
  }

  public static func localeDisplayLabel(
    for identifier: String,
    currentLocale: Locale = .current
  ) -> String {
    let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = localeDisplayName(for: trimmedIdentifier, currentLocale: currentLocale)
    guard displayName != trimmedIdentifier else {
      return trimmedIdentifier
    }
    return "\(displayName) (\(trimmedIdentifier))"
  }
}

extension VoiceProcessingSink {
  public var title: String {
    switch self {
    case .localDaemon:
      "Local daemon"
    case .remoteProcessor:
      "Remote processor"
    case .agentBridge:
      "Agent bridge"
    }
  }
}
