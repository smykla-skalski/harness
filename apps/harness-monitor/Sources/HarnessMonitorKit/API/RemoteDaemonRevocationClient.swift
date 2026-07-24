import Foundation

public protocol RemoteDaemonClientRevoking: Sendable {
  func revoke(profile: RemoteDaemonProfile, token: String) async throws
}

public struct HTTPRemoteDaemonRevocationClient: RemoteDaemonClientRevoking, Sendable {
  public typealias SessionFactory = @Sendable (HarnessMonitorServerTrust) -> URLSession

  private let sessionFactory: SessionFactory

  public init() {
    self.init(sessionFactory: Self.defaultSession)
  }

  public init(sessionFactory: @escaping SessionFactory) {
    self.sessionFactory = sessionFactory
  }

  public func revoke(profile: RemoteDaemonProfile, token: String) async throws {
    guard let url = URL(string: "/v1/remote/client/revoke", relativeTo: profile.endpoint) else {
      throw HarnessMonitorAPIError.invalidEndpoint(profile.endpoint.absoluteString)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    HarnessMonitorConnection(
      endpoint: profile.endpoint,
      token: token,
      remoteClientID: profile.clientID,
      serverTrust: .spkiSHA256(profile.serverSPKISHA256),
      source: .remote(profileID: profile.id)
    ).applyAuthenticationHeaders(to: &request)
    let session = sessionFactory(.spkiSHA256(profile.serverSPKISHA256))
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw HarnessMonitorAPIError.invalidResponse
    }
    if response.statusCode == 401 || (200..<300).contains(response.statusCode) {
      return
    }
    throw HarnessMonitorAPIClient.decodeError(statusCode: response.statusCode, data: data)
  }

  private static func defaultSession(serverTrust: HarnessMonitorServerTrust) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    // Revocation is best-effort and blocks the "Forget Remote Daemon" spinner, so keep the
    // wait short: an unreachable server should fall through to the local forget in seconds.
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 15
    return HarnessMonitorURLSessionFactory.make(
      configuration: configuration,
      serverTrust: serverTrust
    )
  }
}
