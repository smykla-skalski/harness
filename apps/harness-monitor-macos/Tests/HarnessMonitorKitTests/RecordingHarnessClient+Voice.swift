import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func startVoiceSession(
    sessionID: String,
    request: VoiceSessionStartRequest
  ) async throws -> VoiceSessionStartResponse {
    calls.append(
      .startVoiceSession(
        sessionID: sessionID,
        localeIdentifier: request.localeIdentifier,
        sinks: request.requestedSinks,
        routeTarget: request.routeTarget,
        requiresConfirmation: request.requiresConfirmation,
        remoteProcessorURL: request.remoteProcessorUrl,
        actor: request.actor
      )
    )
    return VoiceSessionStartResponse(
      voiceSessionId: "voice-session-1",
      acceptedSinks: request.requestedSinks,
      status: "recording"
    )
  }

  func appendVoiceAudioChunk(
    voiceSessionID: String,
    request: VoiceAudioChunkRequest
  ) async throws -> VoiceSessionMutationResponse {
    calls.append(
      .appendVoiceAudioChunk(
        voiceSessionID: voiceSessionID,
        sequence: request.sequence,
        actor: request.actor
      )
    )
    return VoiceSessionMutationResponse(voiceSessionId: voiceSessionID, status: "recording")
  }

  func appendVoiceTranscript(
    voiceSessionID: String,
    request: VoiceTranscriptUpdateRequest
  ) async throws -> VoiceSessionMutationResponse {
    calls.append(
      .appendVoiceTranscript(
        voiceSessionID: voiceSessionID,
        sequence: request.segment.sequence,
        actor: request.actor
      )
    )
    return VoiceSessionMutationResponse(voiceSessionId: voiceSessionID, status: "recording")
  }

  func finishVoiceSession(
    voiceSessionID: String,
    request: VoiceSessionFinishRequest
  ) async throws -> VoiceSessionMutationResponse {
    calls.append(
      .finishVoiceSession(
        voiceSessionID: voiceSessionID,
        reason: request.reason,
        confirmedText: request.confirmedText,
        actor: request.actor
      )
    )
    return VoiceSessionMutationResponse(voiceSessionId: voiceSessionID, status: request.reason.rawValue)
  }
}
