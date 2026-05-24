import Foundation

extension PreviewHarnessClient {
  public func globalStream() async -> DaemonPushEventStream {
    AsyncThrowingStream { continuation in
      continuation.yield(
        .ready(recordedAt: "2026-03-28T14:00:00Z")
      )
      continuation.finish()
    }
  }

  public func sessionStream(sessionID _: String) async -> DaemonPushEventStream {
    AsyncThrowingStream { continuation in
      continuation.yield(
        .ready(
          recordedAt: "2026-03-28T14:00:00Z",
          sessionId: readySessionID
        )
      )
      continuation.finish()
    }
  }
}
