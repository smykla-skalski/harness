import HarnessMonitorKit
import SwiftUI

public struct PreferencesVoiceSection: View {
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.localeIdentifierKey)
  private var localeIdentifier = HarnessMonitorVoicePreferences.defaultLocaleIdentifier
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.localDaemonSinkEnabledKey)
  private var localDaemonSinkEnabled = true
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.agentBridgeSinkEnabledKey)
  private var agentBridgeSinkEnabled = true
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.remoteProcessorSinkEnabledKey)
  private var remoteProcessorSinkEnabled = false
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.remoteProcessorURLKey)
  private var remoteProcessorURLText = ""
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.transcriptInsertionModeKey)
  private var transcriptInsertionModeRawValue =
    HarnessMonitorVoiceTranscriptInsertionMode.manualConfirm.rawValue
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.deliversAudioChunksKey)
  private var deliversAudioChunks = true
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.pendingAudioChunkLimitKey)
  private var pendingAudioChunkLimit = HarnessMonitorVoicePreferences.defaultPendingAudioChunkLimit
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.pendingTranscriptSegmentLimitKey)
  private var pendingTranscriptSegmentLimit =
    HarnessMonitorVoicePreferences.defaultPendingTranscriptSegmentLimit
  @State private var localeAvailabilityState: VoiceLocaleAvailabilityState = .checking

  public init() {}

  private var preferences: HarnessMonitorVoicePreferences {
    HarnessMonitorVoicePreferences(
      localeIdentifier: localeIdentifier,
      localDaemonSinkEnabled: localDaemonSinkEnabled,
      agentBridgeSinkEnabled: agentBridgeSinkEnabled,
      remoteProcessorSinkEnabled: remoteProcessorSinkEnabled,
      remoteProcessorURLText: remoteProcessorURLText,
      transcriptInsertionModeRawValue: transcriptInsertionModeRawValue,
      deliversAudioChunks: deliversAudioChunks,
      pendingAudioChunkLimit: pendingAudioChunkLimit,
      pendingTranscriptSegmentLimit: pendingTranscriptSegmentLimit
    )
  }

  private var suggestedLocaleOptions: [HarnessMonitorVoiceLocaleOption] {
    HarnessMonitorVoicePreferences.localeOptions(
      selectedLocaleIdentifier: preferences.effectiveLocaleIdentifier
    )
  }

  private var pendingAudioChunkLimitBinding: Binding<Int> {
    Binding(
      get: { pendingAudioChunkLimit },
      set: {
        pendingAudioChunkLimit = HarnessMonitorVoicePreferences.normalizedPendingAudioChunkLimit($0)
      }
    )
  }

  private var pendingTranscriptSegmentLimitBinding: Binding<Int> {
    Binding(
      get: { pendingTranscriptSegmentLimit },
      set: {
        pendingTranscriptSegmentLimit =
          HarnessMonitorVoicePreferences.normalizedPendingTranscriptSegmentLimit($0)
      }
    )
  }

  public var body: some View {
    Form {
      PreferencesVoiceTranscriptionSection(
        localeIdentifier: $localeIdentifier,
        suggestedLocaleOptions: suggestedLocaleOptions,
        selectedLocaleTitle: HarnessMonitorVoicePreferences.localeDisplayLabel(
          for: preferences.effectiveLocaleIdentifier
        )
      )
      PreferencesVoiceProcessingSection(
        localDaemonSinkEnabled: $localDaemonSinkEnabled,
        agentBridgeSinkEnabled: $agentBridgeSinkEnabled,
        remoteProcessorSinkEnabled: $remoteProcessorSinkEnabled,
        requestedSinksSummary: preferences.requestedSinksSummary
      )
      PreferencesVoiceRemoteProcessorSection(
        remoteProcessorSinkEnabled: remoteProcessorSinkEnabled,
        remoteProcessorURLText: $remoteProcessorURLText,
        remoteProcessorStatus: preferences.remoteProcessorStatus
      )
      PreferencesVoiceTranscriptHandlingSection(
        transcriptInsertionModeRawValue: $transcriptInsertionModeRawValue
      )
      PreferencesVoiceAdvancedSection(
        deliversAudioChunks: $deliversAudioChunks,
        pendingAudioChunkLimit: pendingAudioChunkLimitBinding,
        pendingTranscriptSegmentLimit: pendingTranscriptSegmentLimitBinding
      )
      PreferencesVoiceStatusSection(
        preferences: preferences,
        localeAvailabilityState: localeAvailabilityState
      )
    }
    .preferencesDetailFormStyle()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesVoiceSection)
    .task(id: preferences.effectiveLocaleIdentifier) {
      localeAvailabilityState = .checking
      localeAvailabilityState = .resolved(
        await HarnessMonitorVoiceLocaleSupport.availability(
          for: preferences.effectiveLocaleIdentifier
        )
      )
    }
  }
}

private enum VoiceLocaleAvailabilityState: Equatable {
  case checking
  case resolved(HarnessMonitorVoiceLocaleAvailability)
}

private struct PreferencesVoiceTranscriptionSection: View {
  @Binding var localeIdentifier: String
  let suggestedLocaleOptions: [HarnessMonitorVoiceLocaleOption]
  let selectedLocaleTitle: String

  var body: some View {
    Section {
      TextField("Locale identifier", text: $localeIdentifier)
        .harnessNativeFormControl()
        .autocorrectionDisabled()
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesVoiceLocaleField)

      Picker("Common locales", selection: $localeIdentifier) {
        ForEach(suggestedLocaleOptions) { option in
          Text(option.title).tag(option.identifier)
        }
      }
      .harnessNativeFormControl()
      .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesVoiceLocalePicker)

      LabeledContent("Selected language") {
        PreferencesVoiceStatusValue(selectedLocaleTitle)
      }
    } header: {
      Text("Transcription")
    } footer: {
      Text(
        "Harness Monitor tries the selected locale first, then falls back to the current macOS locale "
          + "and English (US) when Speech can map the language."
      )
    }
  }
}

private struct PreferencesVoiceProcessingSection: View {
  @Binding var localDaemonSinkEnabled: Bool
  @Binding var agentBridgeSinkEnabled: Bool
  @Binding var remoteProcessorSinkEnabled: Bool
  let requestedSinksSummary: String

  var body: some View {
    Section {
      Toggle("Local daemon", isOn: $localDaemonSinkEnabled)
        .accessibilityHint("Routes audio to the local harness daemon")
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesVoiceLocalDaemonToggle)
      Toggle("Agent bridge", isOn: $agentBridgeSinkEnabled)
        .accessibilityHint("Routes audio through the agent bridge connection")
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesVoiceAgentBridgeToggle)
      Toggle("Remote processor", isOn: $remoteProcessorSinkEnabled)
        .accessibilityHint("Routes audio to a remote processing service")
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesVoiceRemoteProcessorToggle)

      LabeledContent("Effective sinks") {
        PreferencesVoiceStatusValue(requestedSinksSummary)
      }
    } header: {
      Text("Processing")
    } footer: {
      Text(
        "If every sink is turned off, Harness Monitor still keeps the local daemon enabled "
          + "so the recording session remains routable."
      )
    }
  }
}

private struct PreferencesVoiceRemoteProcessorSection: View {
  let remoteProcessorSinkEnabled: Bool
  @Binding var remoteProcessorURLText: String
  let remoteProcessorStatus: HarnessMonitorVoiceRemoteProcessorStatus

  var body: some View {
    Section {
      TextField("https://processor.example/voice", text: $remoteProcessorURLText)
        .harnessNativeFormControl()
        .autocorrectionDisabled()
        .disabled(!remoteProcessorSinkEnabled)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.preferencesVoiceRemoteProcessorURLField)

      switch remoteProcessorStatus {
      case .disabled:
        Text("The saved endpoint is ignored until the Remote processor sink is enabled.")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      case .invalid:
        Text("Enter a full HTTPS endpoint before recording to a remote processor.")
          .foregroundStyle(HarnessMonitorTheme.danger)
      case .valid(let url):
        Text("Audio and transcript events will be routed to \(url.absoluteString).")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    } header: {
      Text("Remote Processor")
    } footer: {
      Text(
        "This v1 configuration stores a single shared HTTPS endpoint without custom headers or auth tokens."
      )
    }
  }
}

private struct PreferencesVoiceTranscriptHandlingSection: View {
  @Binding var transcriptInsertionModeRawValue: String

  var body: some View {
    Section {
      Picker("Insertion mode", selection: $transcriptInsertionModeRawValue) {
        ForEach(HarnessMonitorVoiceTranscriptInsertionMode.allCases) { mode in
          Text(mode.title).tag(mode.rawValue)
        }
      }
      .harnessNativeFormControl()
      .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesVoiceInsertionModePicker)

      let selectedMode =
        HarnessMonitorVoiceTranscriptInsertionMode(rawValue: transcriptInsertionModeRawValue)
        ?? .manualConfirm
      Text(selectedMode.detail)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    } header: {
      Text("Transcript Handling")
    }
  }
}

private struct PreferencesVoiceAdvancedSection: View {
  @Binding var deliversAudioChunks: Bool
  @Binding var pendingAudioChunkLimit: Int
  @Binding var pendingTranscriptSegmentLimit: Int

  var body: some View {
    Section {
      Toggle("Deliver audio chunks", isOn: $deliversAudioChunks)
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesVoiceAudioChunksToggle)

      PreferencesVoiceNumericField(
        title: "Pending audio chunks",
        value: $pendingAudioChunkLimit,
        range: (HarnessMonitorVoicePreferences
          .minPendingAudioChunkLimit...HarnessMonitorVoicePreferences.maxPendingAudioChunkLimit),
        accessibilityIdentifier: HarnessMonitorAccessibility
          .preferencesVoicePendingAudioField
      )
      PreferencesVoiceNumericField(
        title: "Pending transcript segments",
        value: $pendingTranscriptSegmentLimit,
        range: (HarnessMonitorVoicePreferences
          .minPendingTranscriptSegmentLimit...HarnessMonitorVoicePreferences
          .maxPendingTranscriptSegmentLimit),
        accessibilityIdentifier: HarnessMonitorAccessibility
          .preferencesVoicePendingTranscriptField
      )
    } header: {
      Text("Advanced")
    } footer: {
      Text(
        "Pending limits cap how many events stay buffered locally before the daemon voice session is ready."
      )
    }
  }
}

private struct PreferencesVoiceStatusSection: View {
  let preferences: HarnessMonitorVoicePreferences
  let localeAvailabilityState: VoiceLocaleAvailabilityState

  var body: some View {
    Section {
      LabeledContent("Speech") {
        PreferencesVoiceStatusValue(localeStatusSummary)
      }
      LabeledContent("Recovery") {
        PreferencesVoiceStatusValue(localeRecoverySummary)
      }
      LabeledContent("Remote processor") {
        PreferencesVoiceStatusValue(preferences.remoteProcessorSummary)
      }
      LabeledContent("Transcript flow") {
        PreferencesVoiceStatusValue(preferences.transcriptInsertionSummary)
      }
      LabeledContent("Chunk delivery") {
        PreferencesVoiceStatusValue(preferences.audioChunkDeliverySummary)
      }
    } header: {
      Text("Status & Recovery")
    } footer: {
      Text(
        "Microphone permission is still enforced when recording starts. If speech assets are missing, "
          + "Harness Monitor surfaces the same System Settings recovery path from the voice popover."
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesVoiceStatus)
  }

  private var localeStatusSummary: String {
    switch localeAvailabilityState {
    case .checking:
      "Checking speech availability for \(preferences.effectiveLocaleIdentifier)."
    case .resolved(let availability):
      availability.statusSummary
    }
  }

  private var localeRecoverySummary: String {
    switch localeAvailabilityState {
    case .checking:
      "Loading the current speech and dictation readiness."
    case .resolved(let availability):
      availability.recoverySummary
    }
  }
}

private struct PreferencesVoiceNumericField: View {
  let title: String
  @Binding var value: Int
  let range: ClosedRange<Int>
  let accessibilityIdentifier: String

  var body: some View {
    LabeledContent(title) {
      HStack(spacing: 0) {
        TextField("", value: $value, format: .number)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .multilineTextAlignment(.trailing)
          .frame(width: 56)
          .accessibilityIdentifier(accessibilityIdentifier)
        Stepper("", value: $value, in: range)
          .labelsHidden()
          .controlSize(.small)
      }
    }
  }
}

private struct PreferencesVoiceStatusValue: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .multilineTextAlignment(.trailing)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 280, alignment: .trailing)
  }
}
