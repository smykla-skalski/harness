import Foundation

public enum IntentDaemonError: Error, LocalizedError, Equatable {
  case daemonUnavailable(reason: String)
  case manifestUnreadable(path: String, reason: String)
  case manifestMalformed(path: String, reason: String)
  case invalidEndpoint(value: String)
  case authTokenMissing(path: String, reason: String)
  case authTokenEmpty(path: String)
  case rpcFailed(method: String, message: String)

  public var errorDescription: String? {
    switch self {
    case .daemonUnavailable(let reason):
      "Harness Monitor's sync engine isn't running. \(reason)"
    case .manifestUnreadable(let path, let reason):
      "Couldn't read the daemon manifest at \(path): \(reason)"
    case .manifestMalformed(let path, let reason):
      "The daemon manifest at \(path) is malformed: \(reason)"
    case .invalidEndpoint(let value):
      "Daemon manifest endpoint is not a valid URL: \(value)"
    case .authTokenMissing(let path, let reason):
      "Couldn't read the daemon auth token at \(path): \(reason)"
    case .authTokenEmpty(let path):
      "Daemon auth token file at \(path) is empty"
    case .rpcFailed(let method, let message):
      "Daemon RPC \(method) failed: \(message)"
    }
  }
}
