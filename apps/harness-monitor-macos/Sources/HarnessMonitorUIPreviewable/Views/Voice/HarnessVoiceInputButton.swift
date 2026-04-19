import HarnessMonitorKit
import SwiftUI

struct HarnessVoiceInputButton: View {
  let store: HarnessMonitorStore
  @Binding var text: String
  let label: String
  let routeTarget: () -> VoiceRouteTarget
  let accessibilityIdentifier: String

  @AppStorage(HarnessMonitorVoicePreferencesDefaults.localeIdentifierKey)
  var localeIdentifier = HarnessMonitorVoicePreferences.defaultLocaleIdentifier
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.localDaemonSinkEnabledKey)
  var localDaemonSinkEnabled = true
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.agentBridgeSinkEnabledKey)
  var agentBridgeSinkEnabled = true
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.remoteProcessorSinkEnabledKey)
  var remoteProcessorSinkEnabled = false
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.remoteProcessorURLKey)
  var remoteProcessorURLText = ""
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.transcriptInsertionModeKey)
  var transcriptInsertionModeRawValue =
    HarnessMonitorVoiceTranscriptInsertionMode.manualConfirm.rawValue
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.deliversAudioChunksKey)
  var deliversAudioChunks = true
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.pendingAudioChunkLimitKey)
  var pendingAudioChunkLimit = HarnessMonitorVoicePreferences.defaultPendingAudioChunkLimit
  @AppStorage(HarnessMonitorVoicePreferencesDefaults.pendingTranscriptSegmentLimitKey)
  var pendingTranscriptSegmentLimit =
    HarnessMonitorVoicePreferences.defaultPendingTranscriptSegmentLimit
  @State private var _model = ViewModel()
  @ScaledMetric(relativeTo: .headline)
  private var progressSize: CGFloat = 16

  var model: ViewModel { _model }

  var completeTranscript: String {
    [model.finalTranscript, model.partialTranscript]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  var voicePreferences: HarnessMonitorVoicePreferences {
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

  var body: some View {
    @Bindable var model = model
    return Button {
      model.isPopoverPresented.toggle()
    } label: {
      Label(label, systemImage: "mic.fill")
        .labelStyle(.iconOnly)
    }
    .help(model.isRecording ? "Stop voice capture" : label)
    .accessibilityLabel(label)
    .accessibilityIdentifier(accessibilityIdentifier)
    .popover(isPresented: $model.isPopoverPresented, arrowEdge: .bottom) {
      popoverContent
    }
    .onChange(of: model.isPopoverPresented) { _, isPresented in
      if !isPresented {
        cancelVoiceInteraction()
      }
    }
    .onDisappear {
      cancelVoiceInteraction()
    }
  }

  private var popoverContent: some View {
    ZStack {
      popoverControls
        .blur(radius: model.failurePresentation == nil ? 0 : 2)
        .allowsHitTesting(model.failurePresentation == nil)
        .accessibilityHidden(model.failurePresentation != nil)

      if let failurePresentation = model.failurePresentation {
        VoiceCaptureFailureOverlay(
          presentation: failurePresentation,
          retry: retryAfterFailure,
          close: closeFailure
        )
        .transition(.opacity)
      }
    }
    .frame(width: VoiceCapturePopoverMetrics.width, alignment: .topLeading)
    .frame(minHeight: VoiceCapturePopoverMetrics.minimumHeight, alignment: .topLeading)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .animation(.easeInOut(duration: 0.12), value: model.failurePresentation)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.voiceInputPopover)
  }

  private var popoverControls: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack(spacing: HarnessMonitorTheme.itemSpacing) {
        Label(model.statusText, systemImage: model.isRecording ? "waveform" : "mic")
          .scaledFont(.headline)
          .lineLimit(1)
        Spacer()
        ProgressView()
          .controlSize(.small)
          .frame(width: progressSize, height: progressSize)
          .opacity(model.isRecording ? 1 : 0)
      }
      .frame(height: 22)

      Text(completeTranscript.isEmpty ? "No transcript yet." : completeTranscript)
        .scaledFont(.body)
        .textSelection(.enabled)
        .frame(height: 96, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HarnessMonitorTheme.spacingSM)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier(HarnessMonitorAccessibility.voiceInputTranscript)

      configurationSummary

      HStack(spacing: HarnessMonitorTheme.itemSpacing) {
        captureControl
        insertTranscriptControl
      }
    }
    .padding(HarnessMonitorTheme.spacingLG)
  }

  @ViewBuilder private var captureControl: some View {
    if model.isRecording {
      captureButton
        .harnessActionButtonStyle(variant: .bordered)
        .tint(.red)
    } else {
      captureButton
        .buttonStyle(.borderedProminent)
    }
  }

  private var captureButton: some View {
    Button {
      if model.isRecording {
        stopCaptureOnly()
      } else {
        startCapture()
      }
    } label: {
      Label(captureButtonTitle, systemImage: captureButtonSystemImage)
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity)
    }
    .controlSize(.regular)
    .frame(maxWidth: .infinity)
    .accessibilityIdentifier(HarnessMonitorAccessibility.voiceInputStopButton)
  }

  private var insertTranscriptControl: some View {
    Button("Insert Transcript") {
      insertTranscript()
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.regular)
    .frame(maxWidth: .infinity)
    .disabled(completeTranscript.isEmpty || model.isRecording)
    .accessibilityIdentifier(HarnessMonitorAccessibility.voiceInputInsertButton)
  }

  private var captureButtonTitle: String {
    model.isRecording ? "Stop" : "Record"
  }

  private var captureButtonSystemImage: String {
    model.isRecording ? "stop.fill" : "record.circle"
  }

  private var configurationSummary: some View {
    VoicePopoverConfigurationSummary(preferences: voicePreferences)
  }
}
