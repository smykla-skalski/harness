import HarnessMonitorKit
import SwiftUI

extension HarnessVoiceInputButton {
  func startCapture() {
    guard !model.isRecording else { return }
    model.failurePresentation = nil
    if remoteProcessorSinkEnabled, voicePreferences.remoteProcessorURL == nil {
      model.statusText = "Remote processor endpoint must be HTTPS."
      model.failurePresentation = VoiceCaptureFailurePresentation(
        title: "Remote Processor Unavailable",
        message: "Remote processor endpoint must be a full HTTPS URL.",
        recoverySuggestion:
          "Open Preferences > Voice, turn off Remote processor or save a full HTTPS endpoint, then try again."
      )
      return
    }

    model.finalTranscript = ""
    model.partialTranscript = ""
    model.statusText = "Preparing microphone"
    model.isRecording = true
    model.pendingAutoInsert = voicePreferences.shouldAutoInsertTranscript
    model.captureTask?.cancel()
    model.processingSessionTask?.cancel()
    model.voiceSessionID = nil
    model.pendingAudioChunks.removeAll(keepingCapacity: true)
    model.pendingTranscriptSegments.removeAll(keepingCapacity: true)

    let voicePreferences = self.voicePreferences
    let localeIdentifier = voicePreferences.effectiveLocaleIdentifier
    let routeTarget = routeTarget()
    let sinks = voicePreferences.requestedSinks
    let remoteURL = voicePreferences.remoteProcessorURL
    let processingSessionTask = Task { @MainActor in
      let response = await store.startVoiceProcessingSession(
        localeIdentifier: localeIdentifier,
        requestedSinks: sinks,
        routeTarget: routeTarget,
        remoteProcessorURL: remoteURL,
        requiresConfirmation: voicePreferences.transcriptInsertionMode.requiresConfirmation
      )
      guard !Task.isCancelled else { return response }
      model.voiceSessionID = response?.voiceSessionId
      if let voiceSessionID = response?.voiceSessionId {
        await flushPendingVoiceEvents(voiceSessionID: voiceSessionID)
      } else {
        model.pendingAudioChunks.removeAll(keepingCapacity: true)
        model.pendingTranscriptSegments.removeAll(keepingCapacity: true)
        if model.isRecording {
          model.statusText = "Listening locally"
        }
      }
      return response
    }
    model.processingSessionTask = processingSessionTask

    model.captureTask = Task { @MainActor in
      do {
        for try await event in store.voiceCaptureStream(
          configuration: voicePreferences.captureConfiguration
        ) {
          await handle(event)
        }
        if model.pendingAutoInsert,
          !completeTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          model.isRecording = false
          insertTranscript()
          return
        }
        if model.isRecording {
          model.isRecording = false
        }
        model.statusText = "Stopped"
      } catch {
        model.statusText = "Voice capture failed"
        model.isRecording = false
        model.pendingAutoInsert = false
        processingSessionTask.cancel()
        finishFailedVoiceSession()
        model.failurePresentation = VoiceCaptureFailurePresentation(error: error)
      }
    }
  }

  func handle(_ event: VoiceCaptureEvent) async {
    switch event {
    case .state(let state):
      model.statusText = title(for: state)
      if state == .cancelled || state == .failed {
        model.isRecording = false
      }
    case .audio(let chunk):
      if let voiceSessionID = model.voiceSessionID {
        await store.appendVoiceAudioChunk(voiceSessionID: voiceSessionID, chunk: chunk)
      } else {
        appendPendingAudioChunk(chunk)
      }
    case .transcript(let segment):
      if segment.isFinal {
        appendFinalTranscript(segment.text)
        model.partialTranscript = ""
      } else {
        model.partialTranscript = segment.text
      }
      if let voiceSessionID = model.voiceSessionID {
        await store.appendVoiceTranscript(voiceSessionID: voiceSessionID, segment: segment)
      } else {
        appendPendingTranscriptSegment(segment)
      }
    }
  }

  func stopCaptureOnly() {
    guard model.isRecording else { return }
    model.statusText = "Finishing"
    model.isRecording = false
    Task {
      await store.stopVoiceCapture()
    }
  }

  func cancelVoiceInteraction() {
    let voiceSessionID = model.voiceSessionID
    model.captureTask?.cancel()
    model.processingSessionTask?.cancel()
    model.captureTask = nil
    model.processingSessionTask = nil
    model.voiceSessionID = nil
    model.pendingAutoInsert = false
    model.failurePresentation = nil
    model.pendingAudioChunks.removeAll(keepingCapacity: true)
    model.pendingTranscriptSegments.removeAll(keepingCapacity: true)
    if model.isRecording {
      model.isRecording = false
      model.statusText = "Stopped"
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

  func insertTranscript() {
    let transcript = completeTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcript.isEmpty else { return }
    let bufferedAudioChunks = model.pendingAudioChunks
    let bufferedTranscriptSegments = model.pendingTranscriptSegments
    let activeProcessingSessionTask = model.processingSessionTask
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      text = transcript
    } else {
      text += "\n\n\(transcript)"
    }
    if let voiceSessionID = model.voiceSessionID {
      Task {
        await store.finishVoiceProcessingSession(
          voiceSessionID: voiceSessionID,
          reason: .completed,
          confirmedText: transcript
        )
      }
      model.voiceSessionID = nil
    } else if let activeProcessingSessionTask {
      Task { @MainActor in
        guard let response = await activeProcessingSessionTask.value else { return }
        for chunk in bufferedAudioChunks {
          await store.appendVoiceAudioChunk(voiceSessionID: response.voiceSessionId, chunk: chunk)
        }
        for segment in bufferedTranscriptSegments {
          await store.appendVoiceTranscript(
            voiceSessionID: response.voiceSessionId,
            segment: segment
          )
        }
        await store.finishVoiceProcessingSession(
          voiceSessionID: response.voiceSessionId,
          reason: .completed,
          confirmedText: transcript
        )
      }
    }
    model.captureTask?.cancel()
    model.captureTask = nil
    model.processingSessionTask = nil
    model.pendingAutoInsert = false
    model.failurePresentation = nil
    model.pendingAudioChunks.removeAll(keepingCapacity: true)
    model.pendingTranscriptSegments.removeAll(keepingCapacity: true)
    model.statusText = "Inserted"
    model.isPopoverPresented = false
  }

  func flushPendingVoiceEvents(voiceSessionID: String) async {
    let audioChunks = model.pendingAudioChunks
    let transcriptSegments = model.pendingTranscriptSegments
    model.pendingAudioChunks.removeAll(keepingCapacity: true)
    model.pendingTranscriptSegments.removeAll(keepingCapacity: true)

    for chunk in audioChunks {
      await store.appendVoiceAudioChunk(voiceSessionID: voiceSessionID, chunk: chunk)
    }
    for segment in transcriptSegments {
      await store.appendVoiceTranscript(voiceSessionID: voiceSessionID, segment: segment)
    }
  }

  func appendPendingAudioChunk(_ chunk: VoiceAudioChunk) {
    if model.pendingAudioChunks.count >= voicePreferences.pendingAudioChunkLimit {
      model.pendingAudioChunks.removeFirst()
    }
    model.pendingAudioChunks.append(chunk)
  }

  func appendPendingTranscriptSegment(_ segment: VoiceTranscriptSegment) {
    if model.pendingTranscriptSegments.count >= voicePreferences.pendingTranscriptSegmentLimit {
      model.pendingTranscriptSegments.removeFirst()
    }
    model.pendingTranscriptSegments.append(segment)
  }

  func finishFailedVoiceSession() {
    let failedVoiceSessionID = model.voiceSessionID
    model.voiceSessionID = nil
    model.pendingAudioChunks.removeAll(keepingCapacity: true)
    model.pendingTranscriptSegments.removeAll(keepingCapacity: true)
    guard let failedVoiceSessionID else { return }
    Task {
      await store.finishVoiceProcessingSession(
        voiceSessionID: failedVoiceSessionID,
        reason: .cancelled,
        confirmedText: nil
      )
    }
  }

  func retryAfterFailure() {
    model.failurePresentation = nil
    startCapture()
  }

  func closeFailure() {
    model.failurePresentation = nil
    model.pendingAutoInsert = false
    model.isPopoverPresented = false
  }

  func appendFinalTranscript(_ text: String) {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return }
    if model.finalTranscript.isEmpty {
      model.finalTranscript = trimmedText
    } else if !model.finalTranscript.hasSuffix(trimmedText) {
      model.finalTranscript += " \(trimmedText)"
    }
  }

  func title(for state: VoiceCaptureState) -> String {
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
