import Foundation

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

public enum VoiceRouteTargetKind: String, Codable, Equatable, Sendable {
  case codexPrompt
  case codexContext
  case signal
  case systemFocusedField
}

public struct VoiceRouteTarget: Codable, Equatable, Sendable {
  public let kind: VoiceRouteTargetKind
  public let runId: String?
  public let agentId: String?
  public let command: String?
  public let actionHint: String?

  public init(
    kind: VoiceRouteTargetKind,
    runId: String? = nil,
    agentId: String? = nil,
    command: String? = nil,
    actionHint: String? = nil
  ) {
    self.kind = kind
    self.runId = runId
    self.agentId = agentId
    self.command = command
    self.actionHint = actionHint
  }

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

public enum VoiceProcessingSink: String, Codable, CaseIterable, Equatable, Sendable {
  case localDaemon
  case remoteProcessor
  case agentBridge
}

public struct VoiceAudioFormatDescriptor: Codable, Equatable, Sendable {
  public let sampleRate: Double
  public let channelCount: Int
  public let commonFormat: String
  public let interleaved: Bool

  public init(
    sampleRate: Double,
    channelCount: Int,
    commonFormat: String,
    interleaved: Bool
  ) {
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.commonFormat = commonFormat
    self.interleaved = interleaved
  }
}

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

public struct VoiceTranscriptSegment: Codable, Equatable, Sendable {
  public let sequence: UInt64
  public let text: String
  public let isFinal: Bool
  public let startedAtSeconds: Double
  public let durationSeconds: Double
  public let confidence: Double?

  public init(
    sequence: UInt64,
    text: String,
    isFinal: Bool,
    startedAtSeconds: Double,
    durationSeconds: Double,
    confidence: Double? = nil
  ) {
    self.sequence = sequence
    self.text = text
    self.isFinal = isFinal
    self.startedAtSeconds = startedAtSeconds
    self.durationSeconds = durationSeconds
    self.confidence = confidence
  }
}

public struct VoiceSessionStartRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let localeIdentifier: String
  public let requestedSinks: [VoiceProcessingSink]
  public let routeTarget: VoiceRouteTarget
  public let requiresConfirmation: Bool
  public let remoteProcessorUrl: String?

  public init(
    actor: String,
    localeIdentifier: String,
    requestedSinks: [VoiceProcessingSink],
    routeTarget: VoiceRouteTarget,
    requiresConfirmation: Bool = true,
    remoteProcessorUrl: String? = nil
  ) {
    self.actor = actor
    self.localeIdentifier = localeIdentifier
    self.requestedSinks = requestedSinks
    self.routeTarget = routeTarget
    self.requiresConfirmation = requiresConfirmation
    self.remoteProcessorUrl = remoteProcessorUrl
  }
}

public struct VoiceSessionStartResponse: Codable, Equatable, Sendable {
  public let voiceSessionId: String
  public let acceptedSinks: [VoiceProcessingSink]
  public let status: String

  public init(voiceSessionId: String, acceptedSinks: [VoiceProcessingSink], status: String) {
    self.voiceSessionId = voiceSessionId
    self.acceptedSinks = acceptedSinks
    self.status = status
  }
}

public struct VoiceAudioChunkRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let sequence: UInt64
  public let format: VoiceAudioFormatDescriptor
  public let frameCount: Int
  public let startedAtSeconds: Double
  public let durationSeconds: Double
  public let audioBase64: String

  public init(actor: String, chunk: VoiceAudioChunk) {
    self.actor = actor
    self.sequence = chunk.sequence
    self.format = chunk.format
    self.frameCount = chunk.frameCount
    self.startedAtSeconds = chunk.startedAtSeconds
    self.durationSeconds = chunk.durationSeconds
    self.audioBase64 = chunk.audioData.base64EncodedString()
  }
}

public struct VoiceTranscriptUpdateRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let segment: VoiceTranscriptSegment

  public init(actor: String, segment: VoiceTranscriptSegment) {
    self.actor = actor
    self.segment = segment
  }
}

public enum VoiceSessionFinishReason: String, Codable, Equatable, Sendable {
  case completed
  case cancelled
}

public struct VoiceSessionFinishRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let reason: VoiceSessionFinishReason
  public let confirmedText: String?

  public init(
    actor: String,
    reason: VoiceSessionFinishReason,
    confirmedText: String? = nil
  ) {
    self.actor = actor
    self.reason = reason
    self.confirmedText = confirmedText
  }
}

public struct VoiceSessionMutationResponse: Codable, Equatable, Sendable {
  public let voiceSessionId: String
  public let status: String

  public init(voiceSessionId: String, status: String) {
    self.voiceSessionId = voiceSessionId
    self.status = status
  }
}
