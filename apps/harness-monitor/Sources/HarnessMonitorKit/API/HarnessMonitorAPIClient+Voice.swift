import Foundation

extension HarnessMonitorAPIClient {
  public func startVoiceSession(
    sessionID: String,
    request: VoiceSessionStartRequest
  ) async throws -> VoiceSessionStartResponse {
    try await post(
      "/v1/sessions/\(sessionID)/voice-sessions",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func appendVoiceAudioChunk(
    voiceSessionID: String,
    request: VoiceAudioChunkRequest
  ) async throws -> VoiceSessionMutationResponse {
    try await post(
      "/v1/voice-sessions/\(voiceSessionID)/audio",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func appendVoiceTranscript(
    voiceSessionID: String,
    request: VoiceTranscriptUpdateRequest
  ) async throws -> VoiceSessionMutationResponse {
    try await post(
      "/v1/voice-sessions/\(voiceSessionID)/transcript",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }

  public func finishVoiceSession(
    voiceSessionID: String,
    request: VoiceSessionFinishRequest
  ) async throws -> VoiceSessionMutationResponse {
    try await post(
      "/v1/voice-sessions/\(voiceSessionID)/finish",
      body: request,
      decoder: PolicyWireCoding.decoder
    )
  }
}
