import HarnessMonitorKit
import SwiftUI

struct HarnessVoiceInputButton: View {
  let store: HarnessMonitorStore
  @Binding var text: String
  let label: String
  let routeTarget: () -> VoiceRouteTarget
  let accessibilityIdentifier: String

  @State private var isPopoverPresented = false
  @State private var isRecording = false
  @State private var statusText = "Ready"
  @State private var partialTranscript = ""
  @State private var finalTranscript = ""
  @State private var voiceSessionID: String?
  @State private var captureTask: Task<Void, Never>?
  @State private var processingSessionTask: Task<VoiceSessionStartResponse?, Never>?
  @State private var pendingAudioChunks: [VoiceAudioChunk] = []
  @State private var pendingTranscriptSegments: [VoiceTranscriptSegment] = []
  @State private var localDaemonSinkEnabled = true
  @State private var agentBridgeSinkEnabled = true
  @State private var remoteProcessorSinkEnabled = false
  @State private var remoteProcessorText = ""

  private static let pendingAudioChunkLimit = 24
  private static let pendingTranscriptSegmentLimit = 16

  private var completeTranscript: String {
    [finalTranscript, partialTranscript]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private var selectedSinks: [VoiceProcessingSink] {
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

  var body: some View {
    Button {
      isPopoverPresented.toggle()
    } label: {
      Label(label, systemImage: "mic.fill")
        .labelStyle(.iconOnly)
    }
    .help(isRecording ? "Stop voice capture" : label)
    .accessibilityLabel(label)
    .accessibilityIdentifier(accessibilityIdentifier)
    .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
      popoverContent
    }
    .onChange(of: isPopoverPresented) { _, isPresented in
      if !isPresented {
        cancelVoiceInteraction()
      }
    }
    .onDisappear {
      cancelVoiceInteraction()
    }
  }

  private var popoverContent: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack(spacing: HarnessMonitorTheme.itemSpacing) {
        Label(statusText, systemImage: isRecording ? "waveform" : "mic")
          .scaledFont(.headline)
          .lineLimit(1)
        Spacer()
        ProgressView()
          .controlSize(.small)
          .frame(width: 16, height: 16)
          .opacity(isRecording ? 1 : 0)
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

      sinkControls

      HStack(spacing: HarnessMonitorTheme.itemSpacing) {
        captureControl
        insertTranscriptControl
      }
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(width: 380)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.voiceInputPopover)
  }

  @ViewBuilder
  private var captureControl: some View {
    if isRecording {
      captureButton
        .buttonStyle(.bordered)
        .tint(.red)
    } else {
      captureButton
        .buttonStyle(.borderedProminent)
    }
  }

  private var captureButton: some View {
    Button {
      if isRecording {
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
    .disabled(completeTranscript.isEmpty || isRecording)
    .accessibilityIdentifier(HarnessMonitorAccessibility.voiceInputInsertButton)
  }

  private var captureButtonTitle: String {
    isRecording ? "Stop" : "Record"
  }

  private var captureButtonSystemImage: String {
    isRecording ? "stop.fill" : "record.circle"
  }

  private var sinkControls: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Processing")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Toggle("Local daemon", isOn: $localDaemonSinkEnabled)
      Toggle("Agent bridge", isOn: $agentBridgeSinkEnabled)
      Toggle("Remote processor", isOn: $remoteProcessorSinkEnabled)
      if remoteProcessorSinkEnabled {
        TextField("https://processor.example/voice", text: $remoteProcessorText)
          .harnessNativeFormControl()
          .accessibilityIdentifier(HarnessMonitorAccessibility.voiceInputRemoteURLField)
      }
    }
    .disabled(isRecording)
    .toggleStyle(.checkbox)
  }

  private func startCapture() {
    guard !isRecording else { return }
    if remoteProcessorSinkEnabled, remoteProcessorURL() == nil {
      statusText = "Remote processor URL must be HTTPS."
      return
    }

    finalTranscript = ""
    partialTranscript = ""
    statusText = "Preparing microphone"
    isRecording = true
    captureTask?.cancel()
    processingSessionTask?.cancel()
    voiceSessionID = nil
    pendingAudioChunks.removeAll(keepingCapacity: true)
    pendingTranscriptSegments.removeAll(keepingCapacity: true)

    let localeIdentifier = Locale.current.identifier
    let routeTarget = routeTarget()
    let sinks = selectedSinks
    let remoteURL = remoteProcessorURL()
    let processingSessionTask = Task { @MainActor in
      let response = await store.startVoiceProcessingSession(
        localeIdentifier: localeIdentifier,
        requestedSinks: sinks,
        routeTarget: routeTarget,
        remoteProcessorURL: remoteURL
      )
      guard !Task.isCancelled else { return response }
      voiceSessionID = response?.voiceSessionId
      if let voiceSessionID = response?.voiceSessionId {
        await flushPendingVoiceEvents(voiceSessionID: voiceSessionID)
      } else {
        pendingAudioChunks.removeAll(keepingCapacity: true)
        pendingTranscriptSegments.removeAll(keepingCapacity: true)
        if isRecording {
          statusText = "Listening locally"
        }
      }
      return response
    }
    self.processingSessionTask = processingSessionTask

    captureTask = Task { @MainActor in
      do {
        for try await event in store.voiceCaptureStream(
          configuration: VoiceCaptureConfiguration(
            localeIdentifier: localeIdentifier,
            deliversAudioChunks: !sinks.isEmpty
          )
        ) {
          await handle(event)
        }
        if isRecording {
          statusText = "Stopped"
          isRecording = false
        }
      } catch {
        statusText = error.localizedDescription
        isRecording = false
        processingSessionTask.cancel()
      }
    }
  }

  private func handle(_ event: VoiceCaptureEvent) async {
    switch event {
    case .state(let state):
      statusText = title(for: state)
      if state == .cancelled || state == .failed {
        isRecording = false
      }
    case .audio(let chunk):
      if let voiceSessionID {
        await store.appendVoiceAudioChunk(voiceSessionID: voiceSessionID, chunk: chunk)
      } else {
        appendPendingAudioChunk(chunk)
      }
    case .transcript(let segment):
      if segment.isFinal {
        appendFinalTranscript(segment.text)
        partialTranscript = ""
      } else {
        partialTranscript = segment.text
      }
      if let voiceSessionID {
        await store.appendVoiceTranscript(voiceSessionID: voiceSessionID, segment: segment)
      } else {
        appendPendingTranscriptSegment(segment)
      }
    }
  }

  private func stopCaptureOnly() {
    guard isRecording else { return }
    statusText = "Finishing"
    isRecording = false
    Task {
      await store.stopVoiceCapture()
    }
  }

  private func cancelVoiceInteraction() {
    let voiceSessionID = voiceSessionID
    captureTask?.cancel()
    processingSessionTask?.cancel()
    captureTask = nil
    processingSessionTask = nil
    self.voiceSessionID = nil
    pendingAudioChunks.removeAll(keepingCapacity: true)
    pendingTranscriptSegments.removeAll(keepingCapacity: true)
    if isRecording {
      isRecording = false
      statusText = "Stopped"
    }
    Task {
      await store.stopVoiceCapture()
      if let voiceSessionID {
        await store.finishVoiceProcessingSession(
          voiceSessionID: voiceSessionID,
          reason: .cancelled,
          confirmedText: nil
        )
      }
    }
  }

  private func insertTranscript() {
    let transcript = completeTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcript.isEmpty else { return }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      text = transcript
    } else {
      text += "\n\n\(transcript)"
    }
    if let voiceSessionID {
      Task {
        await store.finishVoiceProcessingSession(
          voiceSessionID: voiceSessionID,
          reason: .completed,
          confirmedText: transcript
        )
      }
      self.voiceSessionID = nil
    }
    captureTask?.cancel()
    processingSessionTask?.cancel()
    captureTask = nil
    processingSessionTask = nil
    pendingAudioChunks.removeAll(keepingCapacity: true)
    pendingTranscriptSegments.removeAll(keepingCapacity: true)
    statusText = "Inserted"
    isPopoverPresented = false
  }

  private func flushPendingVoiceEvents(voiceSessionID: String) async {
    let audioChunks = pendingAudioChunks
    let transcriptSegments = pendingTranscriptSegments
    pendingAudioChunks.removeAll(keepingCapacity: true)
    pendingTranscriptSegments.removeAll(keepingCapacity: true)

    for chunk in audioChunks {
      await store.appendVoiceAudioChunk(voiceSessionID: voiceSessionID, chunk: chunk)
    }
    for segment in transcriptSegments {
      await store.appendVoiceTranscript(voiceSessionID: voiceSessionID, segment: segment)
    }
  }

  private func appendPendingAudioChunk(_ chunk: VoiceAudioChunk) {
    if pendingAudioChunks.count >= Self.pendingAudioChunkLimit {
      pendingAudioChunks.removeFirst()
    }
    pendingAudioChunks.append(chunk)
  }

  private func appendPendingTranscriptSegment(_ segment: VoiceTranscriptSegment) {
    if pendingTranscriptSegments.count >= Self.pendingTranscriptSegmentLimit {
      pendingTranscriptSegments.removeFirst()
    }
    pendingTranscriptSegments.append(segment)
  }

  private func appendFinalTranscript(_ text: String) {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return }
    if finalTranscript.isEmpty {
      finalTranscript = trimmedText
    } else if !finalTranscript.hasSuffix(trimmedText) {
      finalTranscript += " \(trimmedText)"
    }
  }

  private func remoteProcessorURL() -> URL? {
    guard remoteProcessorSinkEnabled else { return nil }
    let trimmedText = remoteProcessorText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmedText), url.scheme == "https" else {
      return nil
    }
    return url
  }

  private func title(for state: VoiceCaptureState) -> String {
    switch state {
    case .idle:
      "Ready"
    case .requestingPermission:
      "Requesting microphone access"
    case .preparingAssets:
      "Preparing speech assets"
    case .recording:
      "Listening"
    case .finishing:
      "Finishing"
    case .cancelled:
      "Stopped"
    case .failed:
      "Voice capture failed"
    }
  }
}
