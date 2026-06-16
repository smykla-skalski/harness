import Foundation

// The voice wire types (VoiceRouteTarget, VoiceProcessingSink,
// VoiceAudioFormatDescriptor, VoiceTranscriptSegment, the request/response
// envelopes, and the route/sink/finish enums) are generated from the Rust
// protocol in Models/Generated/VoiceWireTypes.generated.swift. This file keeps
// the app-only capture surface layered on top of them, plus the ergonomic
// constructors callers reach for.

public typealias VoiceCaptureEventStream = AsyncThrowingStream<VoiceCaptureEvent, Error>

public enum VoiceCaptureState: String, Codable, Equatable, Sendable {
  case idle
  case requestingPermission
  case preparingAssets
  case recording
  case finishing
  case cancelled
  case failed
}

public enum VoiceCaptureEvent: Equatable, Sendable {
  case state(VoiceCaptureState)
  case audio(VoiceAudioChunk)
  case transcript(VoiceTranscriptSegment)
}

public struct VoiceCaptureConfiguration: Equatable, Sendable {
  public let localeIdentifier: String
  public let deliversAudioChunks: Bool

  public init(
    localeIdentifier: String = Locale.current.identifier,
    deliversAudioChunks: Bool = true
  ) {
    self.localeIdentifier = localeIdentifier
    self.deliversAudioChunks = deliversAudioChunks
  }
}

public protocol VoiceCaptureProviding: Sendable {
  func capture(configuration: VoiceCaptureConfiguration) -> VoiceCaptureEventStream
  func stop() async
}

/// In-process audio buffer carried on the capture stream. Distinct from the
/// generated `VoiceAudioChunkRequest` wire type, which carries the buffer as
/// base64 for the daemon.
public struct VoiceAudioChunk: Codable, Equatable, Sendable {
  public let sequence: UInt64
  public let format: VoiceAudioFormatDescriptor
  public let frameCount: Int
  public let startedAtSeconds: Double
  public let durationSeconds: Double
  public let audioData: Data

  public init(
    sequence: UInt64,
    format: VoiceAudioFormatDescriptor,
    frameCount: Int,
    startedAtSeconds: Double,
    durationSeconds: Double,
    audioData: Data
  ) {
    self.sequence = sequence
    self.format = format
    self.frameCount = frameCount
    self.startedAtSeconds = startedAtSeconds
    self.durationSeconds = durationSeconds
    self.audioData = audioData
  }
}

extension VoiceRouteTarget {
  public static let codexPrompt = Self(kind: .codexPrompt)

  public static func codexContext(runID: String?) -> Self {
    Self(kind: .codexContext, runId: runID)
  }

  public static func signal(
    agentID: String,
    command: String,
    actionHint: String?
  ) -> Self {
    Self(
      kind: .signal,
      agentId: agentID,
      command: command,
      actionHint: actionHint
    )
  }

  public static let systemFocusedField = Self(kind: .systemFocusedField)
}

extension VoiceAudioChunkRequest {
  public init(actor: String, chunk: VoiceAudioChunk) {
    self.init(
      actor: actor,
      sequence: chunk.sequence,
      format: chunk.format,
      frameCount: UInt(chunk.frameCount),
      startedAtSeconds: chunk.startedAtSeconds,
      durationSeconds: chunk.durationSeconds,
      audioBase64: chunk.audioData.base64EncodedString()
    )
  }
}
