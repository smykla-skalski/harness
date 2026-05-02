import Foundation

extension HarnessMonitorAPIClient {
  public func startVoiceSession(
    sessionID: String,
    request: VoiceSessionStartRequest
  ) async throws -> VoiceSessionStartResponse {
    try await post("/v1/sessions/\(sessionID)/voice-sessions", body: request)
  }

  public func appendVoiceAudioChunk(
    voiceSessionID: String,
    request: VoiceAudioChunkRequest
  ) async throws -> VoiceSessionMutationResponse {
    try await post("/v1/voice-sessions/\(voiceSessionID)/audio", body: request)
  }

  public func appendVoiceTranscript(
    voiceSessionID: String,
    request: VoiceTranscriptUpdateRequest
  ) async throws -> VoiceSessionMutationResponse {
    try await post("/v1/voice-sessions/\(voiceSessionID)/transcript", body: request)
  }

  public func finishVoiceSession(
    voiceSessionID: String,
    request: VoiceSessionFinishRequest
  ) async throws -> VoiceSessionMutationResponse {
    try await post("/v1/voice-sessions/\(voiceSessionID)/finish", body: request)
  }
}
