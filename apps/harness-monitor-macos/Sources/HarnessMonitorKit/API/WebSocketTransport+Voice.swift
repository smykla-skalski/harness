import Foundation

extension WebSocketTransport {
  public func startVoiceSession(
    sessionID: String,
    request: VoiceSessionStartRequest
  ) async throws -> VoiceSessionStartResponse {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await rpc(method: .voiceStartSession, params: params)
    return try decode(value)
  }

  public func appendVoiceAudioChunk(
    voiceSessionID: String,
    request: VoiceAudioChunkRequest
  ) async throws -> VoiceSessionMutationResponse {
    let params = try encodeParams(request, extra: ["voice_session_id": .string(voiceSessionID)])
    let value = try await rpc(method: .voiceAppendAudio, params: params)
    return try decode(value)
  }

  public func appendVoiceTranscript(
    voiceSessionID: String,
    request: VoiceTranscriptUpdateRequest
  ) async throws -> VoiceSessionMutationResponse {
    let params = try encodeParams(request, extra: ["voice_session_id": .string(voiceSessionID)])
    let value = try await rpc(method: .voiceAppendTranscript, params: params)
    return try decode(value)
  }

  public func finishVoiceSession(
    voiceSessionID: String,
    request: VoiceSessionFinishRequest
  ) async throws -> VoiceSessionMutationResponse {
    let params = try encodeParams(request, extra: ["voice_session_id": .string(voiceSessionID)])
    let value = try await rpc(method: .voiceFinishSession, params: params)
    return try decode(value)
  }
}
