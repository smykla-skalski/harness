import Foundation

actor PreviewHostBridgeState {
  struct ManifestState: Sendable {
    let sandboxed: Bool
    let hostBridge: HostBridgeManifest
  }

  private var bridgeStatus: BridgeStatusReport?
  private let reconfigureBehavior: PreviewHostBridgeReconfigureBehavior

  init(override hostBridgeOverride: PreviewHostBridgeOverride?) {
    bridgeStatus = hostBridgeOverride?.bridgeStatus
    reconfigureBehavior = hostBridgeOverride?.reconfigureBehavior ?? .unsupported
  }

  func manifestState() -> ManifestState {
    guard let bridgeStatus else {
      return ManifestState(sandboxed: false, hostBridge: HostBridgeManifest())
    }
    return ManifestState(
      sandboxed: true,
      hostBridge: bridgeStatus.hostBridgeManifest
    )
  }

  func reconfigure(request: HostBridgeReconfigureRequest) throws -> BridgeStatusReport {
    guard var bridgeStatus else {
      throw HarnessMonitorAPIError.server(code: 501, message: "Host bridge unavailable.")
    }

    switch reconfigureBehavior {
    case .unsupported:
      throw HarnessMonitorAPIError.server(code: 501, message: "Host bridge unavailable.")
    case .missingRoute:
      throw HarnessMonitorAPIError.server(code: 404, message: "Route not found.")
    case .bridgeStopped:
      throw HarnessMonitorAPIError.server(code: 400, message: "bridge is not running")
    case .apply:
      var capabilities = bridgeStatus.capabilities
      for capability in request.enable {
        capabilities[capability] = previewHostBridgeCapabilityManifest(
          capability: capability,
          existing: capabilities[capability]
        )
      }
      for capability in request.disable {
        capabilities.removeValue(forKey: capability)
      }

      bridgeStatus = BridgeStatusReport(
        running: bridgeStatus.running,
        socketPath: bridgeStatus.socketPath,
        pid: bridgeStatus.pid,
        startedAt: bridgeStatus.startedAt,
        uptimeSeconds: bridgeStatus.uptimeSeconds,
        capabilities: capabilities
      )
      self.bridgeStatus = bridgeStatus
      return bridgeStatus
    }
  }

  private func previewHostBridgeCapabilityManifest(
    capability: String,
    existing: HostBridgeCapabilityManifest?
  ) -> HostBridgeCapabilityManifest {
    if let existing {
      return HostBridgeCapabilityManifest(
        enabled: true,
        healthy: true,
        transport: existing.transport,
        endpoint: existing.endpoint,
        metadata: existing.metadata
      )
    }

    switch capability {
    case "codex":
      return HostBridgeCapabilityManifest(
        healthy: true,
        transport: "websocket",
        endpoint: "ws://127.0.0.1:4545"
      )
    case "agent-tui":
      return HostBridgeCapabilityManifest(
        healthy: true,
        transport: "unix",
        endpoint: "/tmp/harness-preview-bridge.sock",
        metadata: ["active_sessions": "0"]
      )
    default:
      return HostBridgeCapabilityManifest(
        healthy: true,
        transport: "preview"
      )
    }
  }
}

public actor PreviewVoiceCaptureService: VoiceCaptureProviding {
  public enum Behavior: Sendable {
    case transcript(String)
    case failure(any Error & Sendable)
  }

  public struct PreviewFailure: LocalizedError, Sendable {
    public let message: String

    public init(message: String) {
      self.message = message
    }

    public var errorDescription: String? {
      message
    }
  }

  public static let defaultTranscript = "Preview voice input for Harness Monitor"

  private let behavior: Behavior
  private var continuation: VoiceCaptureEventStream.Continuation?
  private var emissionTask: Task<Void, Never>?

  public init(behavior: Behavior? = nil) {
    self.behavior = behavior ?? .transcript(Self.defaultTranscript)
  }

  nonisolated public func capture(configuration _: VoiceCaptureConfiguration)
    -> VoiceCaptureEventStream
  {
    VoiceCaptureEventStream { continuation in
      let task = Task {
        await self.start(continuation: continuation)
      }
      continuation.onTermination = { _ in
        task.cancel()
        Task {
          await self.stop()
        }
      }
    }
  }

  public func stop() async {
    emissionTask?.cancel()
    emissionTask = nil
    continuation?.yield(.state(.cancelled))
    continuation?.finish()
    continuation = nil
  }

  private func start(continuation: VoiceCaptureEventStream.Continuation) {
    emissionTask?.cancel()
    self.continuation = continuation
    continuation.yield(.state(.requestingPermission))
    continuation.yield(.state(.recording))
    emissionTask = Task {
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      switch behavior {
      case .transcript(let text):
        continuation.yield(
          .transcript(
            VoiceTranscriptSegment(
              sequence: 1,
              text: text,
              isFinal: true,
              startedAtSeconds: 0,
              durationSeconds: 0.5
            )
          )
        )
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        continuation.yield(.state(.finishing))
        continuation.finish()
      case .failure(let error):
        continuation.yield(.state(.failed))
        continuation.finish(throwing: error)
      }
    }
  }
}
