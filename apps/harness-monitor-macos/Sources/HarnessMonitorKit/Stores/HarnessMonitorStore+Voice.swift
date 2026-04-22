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
    let actionName = "Start voice session"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return nil }
    guard let actor = actionActor(for: actor, actionName: actionName) else { return nil }

    do {
      return try await action.client.startVoiceSession(
        sessionID: action.sessionID,
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
    let actionName = "Append voice audio"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    guard let actor = actionActor(for: actor, actionName: actionName) else { return false }

    do {
      _ = try await action.client.appendVoiceAudioChunk(
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
    let actionName = "Append voice transcript"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    guard let actor = actionActor(for: actor, actionName: actionName) else { return false }

    do {
      _ = try await action.client.appendVoiceTranscript(
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
    let actionName = "Finish voice session"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    guard let actor = actionActor(for: actor, actionName: actionName) else { return false }

    do {
      _ = try await action.client.finishVoiceSession(
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
