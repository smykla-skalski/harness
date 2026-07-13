@testable import HarnessMonitorKit

struct SuccessfulRemoteDaemonRevoker: RemoteDaemonClientRevoking {
  func revoke(profile: RemoteDaemonProfile, token: String) async throws {}
}

enum FailingRemoteDaemonRevokerError: Error {
  case rejected
}

struct FailingRemoteDaemonRevoker: RemoteDaemonClientRevoking {
  func revoke(profile: RemoteDaemonProfile, token: String) async throws {
    throw FailingRemoteDaemonRevokerError.rejected
  }
}
