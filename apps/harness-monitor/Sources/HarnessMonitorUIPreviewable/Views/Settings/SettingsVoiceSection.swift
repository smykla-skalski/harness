import HarnessMonitorKit
import SwiftUI

public struct SettingsVoiceSection: View {
  @AppStorage(HarnessMonitorVoiceSettingsDefaults.localeIdentifierKey)
  private var localeIdentifier = HarnessMonitorVoiceSettings.defaultLocaleIdentifier
  @AppStorage(HarnessMonitorVoiceSettingsDefaults.localDaemonSinkEnabledKey)
  private var localDaemonSinkEnabled = true
  @AppStorage(HarnessMonitorVoiceSettingsDefaults.agentBridgeSinkEnabledKey)
  private var agentBridgeSinkEnabled = true
  @AppStorage(HarnessMonitorVoiceSettingsDefaults.remoteProcessorSinkEnabledKey)
  private var remoteProcessorSinkEnabled = false
  @AppStorage(HarnessMonitorVoiceSettingsDefaults.remoteProcessorURLKey)
  private var remoteProcessorURLText = ""
  @AppStorage(HarnessMonitorVoiceSettingsDefaults.transcriptInsertionModeKey)
  private var transcriptInsertionModeRawValue =
    HarnessMonitorVoiceTranscriptInsertionMode.manualConfirm.rawValue
  @AppStorage(HarnessMonitorVoiceSettingsDefaults.deliversAudioChunksKey)
  private var deliversAudioChunks = true
  @AppStorage(HarnessMonitorVoiceSettingsDefaults.pendingAudioChunkLimitKey)
  private var pendingAudioChunkLimit = HarnessMonitorVoiceSettings.defaultPendingAudioChunkLimit
  @AppStorage(HarnessMonitorVoiceSettingsDefaults.pendingTranscriptSegmentLimitKey)
  private var pendingTranscriptSegmentLimit =
    HarnessMonitorVoiceSettings.defaultPendingTranscriptSegmentLimit
  @State private var localeAvailabilityState: VoiceLocaleAvailabilityState = .checking
  @State private var isFullyExpanded = false

  public init() {}

  private var settings: HarnessMonitorVoiceSettings {
    HarnessMonitorVoiceSettings(
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
    HarnessMonitorVoiceSettings.localeOptions(
      selectedLocaleIdentifier: settings.effectiveLocaleIdentifier
    )
  }

  private var pendingAudioChunkLimitBinding: Binding<Int> {
    Binding(
      get: { pendingAudioChunkLimit },
      set: {
        pendingAudioChunkLimit = HarnessMonitorVoiceSettings.normalizedPendingAudioChunkLimit($0)
      }
    )
  }

  private var pendingTranscriptSegmentLimitBinding: Binding<Int> {
    Binding(
      get: { pendingTranscriptSegmentLimit },
      set: {
        pendingTranscriptSegmentLimit =
          HarnessMonitorVoiceSettings.normalizedPendingTranscriptSegmentLimit($0)
      }
    )
  }

  public var body: some View {
    Form {
      SettingsVoiceTranscriptionSection(
        localeIdentifier: $localeIdentifier,
        suggestedLocaleOptions: suggestedLocaleOptions,
        selectedLocaleTitle: HarnessMonitorVoiceSettings.localeDisplayLabel(
          for: settings.effectiveLocaleIdentifier
        )
      )
      if isFullyExpanded {
        SettingsVoiceProcessingSection(
          localDaemonSinkEnabled: $localDaemonSinkEnabled,
          agentBridgeSinkEnabled: $agentBridgeSinkEnabled,
          remoteProcessorSinkEnabled: $remoteProcessorSinkEnabled,
          requestedSinksSummary: settings.requestedSinksSummary
        )
        SettingsVoiceRemoteProcessorSection(
          remoteProcessorSinkEnabled: remoteProcessorSinkEnabled,
          remoteProcessorURLText: $remoteProcessorURLText,
          remoteProcessorStatus: settings.remoteProcessorStatus
        )
        SettingsVoiceTranscriptHandlingSection(
          transcriptInsertionModeRawValue: $transcriptInsertionModeRawValue
        )
        SettingsVoiceAdvancedSection(
          deliversAudioChunks: $deliversAudioChunks,
          pendingAudioChunkLimit: pendingAudioChunkLimitBinding,
          pendingTranscriptSegmentLimit: pendingTranscriptSegmentLimitBinding
        )
        SettingsVoiceStatusSection(
          settings: settings,
          localeAvailabilityState: localeAvailabilityState
        )
      }
    }
    .settingsDetailFormStyle()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsVoiceSection)
    .task { await expandAfterFirstFrame() }
    .task(id: settings.effectiveLocaleIdentifier) {
      localeAvailabilityState = .checking
      localeAvailabilityState = .resolved(
        await HarnessMonitorVoiceLocaleSupport.availability(
          for: settings.effectiveLocaleIdentifier
        )
      )
    }
  }

  private func expandAfterFirstFrame() async {
    guard !isFullyExpanded else { return }
    try? await Task.sleep(for: .milliseconds(40))
    isFullyExpanded = true
  }
}

private enum VoiceLocaleAvailabilityState: Equatable {
  case checking
  case resolved(HarnessMonitorVoiceLocaleAvailability)
}

private struct SettingsVoiceTranscriptionSection: View {
  @Binding var localeIdentifier: String
  let suggestedLocaleOptions: [HarnessMonitorVoiceLocaleOption]
  let selectedLocaleTitle: String

  var body: some View {
    Section {
      TextField("Locale identifier", text: $localeIdentifier)
        .harnessNativeFormControl()
        .autocorrectionDisabled()
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsVoiceLocaleField)

      Picker("Common locales", selection: $localeIdentifier) {
        ForEach(suggestedLocaleOptions) { option in
          Text(option.title).tag(option.identifier)
        }
      }
      .harnessNativeFormControl()
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsVoiceLocalePicker)

      LabeledContent("Selected language") {
        SettingsVoiceStatusValue(selectedLocaleTitle)
      }
    } header: {
      Text("Transcription")
    } footer: {
      Text(
        "Harness Monitor tries the selected locale first, then falls back to the current macOS locale "
          + "and English (US) when Speech can map the language"
      )
    }
  }
}

private struct SettingsVoiceProcessingSection: View {
  @Binding var localDaemonSinkEnabled: Bool
  @Binding var agentBridgeSinkEnabled: Bool
  @Binding var remoteProcessorSinkEnabled: Bool
  let requestedSinksSummary: String

  var body: some View {
    Section {
      Toggle("Local daemon", isOn: $localDaemonSinkEnabled)
        .accessibilityHint("Routes audio to the local harness daemon")
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsVoiceLocalDaemonToggle)
      Toggle("Agent bridge", isOn: $agentBridgeSinkEnabled)
        .accessibilityHint("Routes audio through the agent bridge connection")
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsVoiceAgentBridgeToggle)
      Toggle("Remote processor", isOn: $remoteProcessorSinkEnabled)
        .accessibilityHint("Routes audio to a remote processing service")
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsVoiceRemoteProcessorToggle)

      LabeledContent("Effective sinks") {
        SettingsVoiceStatusValue(requestedSinksSummary)
      }
    } header: {
      Text("Processing")
    } footer: {
      Text(
        "If every sink is turned off, Harness Monitor still keeps the local daemon enabled "
          + "so the recording session remains routable"
      )
    }
  }
}

private struct SettingsVoiceRemoteProcessorSection: View {
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
          HarnessMonitorAccessibility.settingsVoiceRemoteProcessorURLField)

      switch remoteProcessorStatus {
      case .disabled:
        Text("The saved endpoint is ignored until the Remote processor sink is enabled")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      case .invalid:
        Text("Enter a full HTTPS endpoint before recording to a remote processor")
          .foregroundStyle(HarnessMonitorTheme.danger)
      case .valid(let url):
        Text("Audio and transcript events will be routed to \(url.absoluteString)")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    } header: {
      Text("Remote Processor")
    } footer: {
      Text(
        "This v1 configuration stores a single shared HTTPS endpoint without custom headers or auth tokens"
      )
    }
  }
}

private struct SettingsVoiceTranscriptHandlingSection: View {
  @Binding var transcriptInsertionModeRawValue: String

  var body: some View {
    Section {
      Picker("Insertion mode", selection: $transcriptInsertionModeRawValue) {
        ForEach(HarnessMonitorVoiceTranscriptInsertionMode.allCases) { mode in
          Text(mode.title).tag(mode.rawValue)
        }
      }
      .harnessNativeFormControl()
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsVoiceInsertionModePicker)

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

private struct SettingsVoiceAdvancedSection: View {
  @Binding var deliversAudioChunks: Bool
  @Binding var pendingAudioChunkLimit: Int
  @Binding var pendingTranscriptSegmentLimit: Int

  var body: some View {
    Section {
      Toggle("Deliver audio chunks", isOn: $deliversAudioChunks)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsVoiceAudioChunksToggle)

      SettingsVoiceNumericField(
        title: "Pending audio chunks",
        value: $pendingAudioChunkLimit,
        range: (HarnessMonitorVoiceSettings
          .minPendingAudioChunkLimit...HarnessMonitorVoiceSettings.maxPendingAudioChunkLimit),
        accessibilityIdentifier: HarnessMonitorAccessibility
          .settingsVoicePendingAudioField
      )
      SettingsVoiceNumericField(
        title: "Pending transcript segments",
        value: $pendingTranscriptSegmentLimit,
        range: (HarnessMonitorVoiceSettings
          .minPendingTranscriptSegmentLimit...HarnessMonitorVoiceSettings
          .maxPendingTranscriptSegmentLimit),
        accessibilityIdentifier: HarnessMonitorAccessibility
          .settingsVoicePendingTranscriptField
      )
    } header: {
      Text("Advanced")
    } footer: {
      Text(
        "Pending limits cap how many events stay buffered locally before the daemon voice session is ready"
      )
    }
  }
}

private struct SettingsVoiceStatusSection: View {
  let settings: HarnessMonitorVoiceSettings
  let localeAvailabilityState: VoiceLocaleAvailabilityState

  var body: some View {
    Section {
      LabeledContent("Speech") {
        SettingsVoiceStatusValue(localeStatusSummary)
      }
      LabeledContent("Recovery") {
        SettingsVoiceStatusValue(localeRecoverySummary)
      }
      LabeledContent("Remote processor") {
        SettingsVoiceStatusValue(settings.remoteProcessorSummary)
      }
      LabeledContent("Transcript flow") {
        SettingsVoiceStatusValue(settings.transcriptInsertionSummary)
      }
      LabeledContent("Chunk delivery") {
        SettingsVoiceStatusValue(settings.audioChunkDeliverySummary)
      }
    } header: {
      Text("Status & Recovery")
    } footer: {
      Text(
        "Microphone permission is still enforced when recording starts. If speech assets are missing, "
          + "Harness Monitor surfaces the same System Settings recovery path from the voice popover"
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsVoiceStatus)
  }

  private var localeStatusSummary: String {
    switch localeAvailabilityState {
    case .checking:
      "Checking speech availability for \(settings.effectiveLocaleIdentifier)"
    case .resolved(let availability):
      availability.statusSummary
    }
  }

  private var localeRecoverySummary: String {
    switch localeAvailabilityState {
    case .checking:
      "Loading the current speech and dictation readiness"
    case .resolved(let availability):
      availability.recoverySummary
    }
  }
}

private struct SettingsVoiceNumericField: View {
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

private struct SettingsVoiceStatusValue: View {
  let text: String

  init(_ text: String) {
    self.text = text.harnessMonitorTrimmedTrailingPeriod
  }

  var body: some View {
    Text(text)
      .lineLimit(1)
      .truncationMode(.tail)
      .multilineTextAlignment(.trailing)
  }
}
