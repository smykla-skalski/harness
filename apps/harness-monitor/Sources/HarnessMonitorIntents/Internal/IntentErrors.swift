import Foundation

public enum IntentDaemonError: Error, LocalizedError, Equatable {
  case daemonUnavailable(reason: String)
  case manifestUnreadable(path: String, reason: String)
  case manifestMalformed(path: String, reason: String)
  case invalidEndpoint(value: String)
  case authTokenMissing(path: String, reason: String)
  case authTokenEmpty(path: String)
  case rpcFailed(method: String, message: String)

  /// User-facing description. This is what Siri reads aloud and what
  /// Spotlight / Shortcuts surfaces in error UI, so it must be plain
  /// English and free of raw daemon / WebSocket jargon. Diagnostic
  /// detail goes in `failureReason` instead.
  public var errorDescription: String? {
    switch self {
    case .daemonUnavailable, .manifestUnreadable, .invalidEndpoint:
      "Harness Monitor isn't reachable. Open it on your Mac and try again"
    case .manifestMalformed:
      "Harness Monitor's connection info is corrupted. Restart the app and try again"
    case .authTokenMissing, .authTokenEmpty:
      "Harness Monitor's credentials are missing. Open it on your Mac and sign in"
    case .rpcFailed(_, let message):
      Self.friendlyMessage(forRawRPCMessage: message)
    }
  }

  /// Raw diagnostic detail. `LocalizedError.failureReason` is appended to
  /// the user-facing description in some surfaces (e.g. `NSError`
  /// alert sheets) and is preserved verbatim in Console.app logs.
  public var failureReason: String? {
    switch self {
    case .daemonUnavailable(let reason),
      .manifestUnreadable(_, let reason),
      .manifestMalformed(_, let reason),
      .authTokenMissing(_, let reason):
      reason
    case .invalidEndpoint(let value):
      "endpoint=\(value)"
    case .authTokenEmpty(let path):
      "path=\(path)"
    case .rpcFailed(let method, let message):
      "rpc=\(method) detail=\(message)"
    }
  }

  /// Maps a raw transport-level RPC error message to a user-facing
  /// summary. Exposed for tests so we can pin the contract without
  /// constructing actual `WebSocketTransportError` values.
  public static func friendlyMessage(forRawRPCMessage message: String) -> String {
    let lower = message.lowercased()
    if lower.contains("connection closed")
      || lower.contains("upgrade rejected")
      || lower.contains("could not connect")
      || lower.contains("not connected")
      || lower.contains("connection refused")
      || lower.contains("network connection was lost")
    {
      return "Harness Monitor isn't reachable right now. Open it on your Mac and try again"
    }
    if lower.contains("did not respond")
      || lower.contains("timed out")
      || lower.contains("timeout")
    {
      return "Harness Monitor took too long to respond. Try again in a moment"
    }
    if lower.contains("unauthorized")
      || lower.contains("forbidden")
      || lower.contains("not authorized")
      || lower.contains("auth token")
    {
      return "Harness Monitor's credentials need refreshing. Open it on your Mac and sign in"
    }
    if lower.contains("not found") {
      return "Harness Monitor couldn't find that item. It may have moved or been closed"
    }
    return "Harness Monitor couldn't complete the request. Try again in a moment"
  }
}
