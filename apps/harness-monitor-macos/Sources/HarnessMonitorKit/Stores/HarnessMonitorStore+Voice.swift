import Foundation

extension HarnessMonitorStore {
  public func voiceCaptureStream(
    configuration: VoiceCaptureConfiguration = VoiceCaptureConfiguration()
  ) -> VoiceCaptureEventStream {
    voiceCapture.capture(configuration: configuration)
  }

  public func stopVoiceCapture() async {
    await voiceCapture.stop()
  }

  public func startVoiceProcessingSession(
    localeIdentifier: String,
    requestedSinks: [VoiceProcessingSink],
    routeTarget: VoiceRouteTarget,
    remoteProcessorURL: URL?,
    requiresConfirmation: Bool,
    actor: String = "harness-app"
  ) async -> VoiceSessionStartResponse? {
    guard guardSessionActionsAvailable() else { return nil }
    guard let client, let sessionID = selectedSessionID else { return nil }
    guard let actor = actionActor(for: actor) else { return nil }

    do {
      return try await client.startVoiceSession(
        sessionID: sessionID,
        request: VoiceSessionStartRequest(
          actor: actor,
          localeIdentifier: localeIdentifier,
          requestedSinks: requestedSinks,
          routeTarget: routeTarget,
          requiresConfirmation: requiresConfirmation,
          remoteProcessorUrl: remoteProcessorURL?.absoluteString
        )
      )
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  @discardableResult
  public func appendVoiceAudioChunk(
    voiceSessionID: String,
    chunk: VoiceAudioChunk,
    actor: String = "harness-app"
  ) async -> Bool {
    guard let client else { return false }
    guard let actor = actionActor(for: actor) else { return false }

    do {
      _ = try await client.appendVoiceAudioChunk(
        voiceSessionID: voiceSessionID,
        request: VoiceAudioChunkRequest(actor: actor, chunk: chunk)
      )
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  @discardableResult
  public func appendVoiceTranscript(
    voiceSessionID: String,
    segment: VoiceTranscriptSegment,
    actor: String = "harness-app"
  ) async -> Bool {
    guard let client else { return false }
    guard let actor = actionActor(for: actor) else { return false }

    do {
      _ = try await client.appendVoiceTranscript(
        voiceSessionID: voiceSessionID,
        request: VoiceTranscriptUpdateRequest(actor: actor, segment: segment)
      )
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  @discardableResult
  public func finishVoiceProcessingSession(
    voiceSessionID: String,
    reason: VoiceSessionFinishReason,
    confirmedText: String?,
    actor: String = "harness-app"
  ) async -> Bool {
    guard let client else { return false }
    guard let actor = actionActor(for: actor) else { return false }

    do {
      _ = try await client.finishVoiceSession(
        voiceSessionID: voiceSessionID,
        request: VoiceSessionFinishRequest(
          actor: actor,
          reason: reason,
          confirmedText: confirmedText
        )
      )
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }
}
