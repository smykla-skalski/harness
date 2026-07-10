import Foundation

public struct RemoteDaemonPairingClaim: Equatable, Sendable {
  public let clientID: String
  public let displayName: String
  public let platform: String
  public let role: RemoteDaemonRole
  public let scopes: [String]
  public let token: String
  public let tokenHint: String
  public let pairedAt: Date

  public init(
    clientID: String,
    displayName: String,
    platform: String,
    role: RemoteDaemonRole,
    scopes: [String],
    token: String,
    tokenHint: String,
    pairedAt: Date
  ) {
    self.clientID = clientID
    self.displayName = displayName
    self.platform = platform
    self.role = role
    self.scopes = scopes
    self.token = token
    self.tokenHint = tokenHint
    self.pairedAt = pairedAt
  }
}

public protocol RemoteDaemonPairingClaiming: Sendable {
  func claim(
    invitation: RemoteDaemonPairingInvitation,
    clientID: String,
    displayName: String,
    platform: String
  ) async throws -> RemoteDaemonPairingClaim
}

public struct HTTPRemoteDaemonPairingClient: RemoteDaemonPairingClaiming, Sendable {
  public typealias SessionFactory = @Sendable (HarnessMonitorServerTrust) -> URLSession

  private let sessionFactory: SessionFactory

  public init() {
    self.init(sessionFactory: Self.defaultSession)
  }

  public init(sessionFactory: @escaping SessionFactory) {
    self.sessionFactory = sessionFactory
  }

  private static func defaultSession(serverTrust: HarnessMonitorServerTrust) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    return HarnessMonitorURLSessionFactory.make(
      configuration: configuration,
      serverTrust: serverTrust
    )
  }

  public func claim(
    invitation: RemoteDaemonPairingInvitation,
    clientID: String,
    displayName: String,
    platform: String
  ) async throws -> RemoteDaemonPairingClaim {
    guard
      let url = URL(string: "/v1/remote/pair/claim", relativeTo: invitation.endpoint)
    else {
      throw HarnessMonitorAPIError.invalidEndpoint(invitation.endpoint.absoluteString)
    }
    let body = RemoteDaemonPairingClaimRequest(
      code: invitation.code,
      domain: invitation.endpoint.host ?? "",
      clientID: clientID,
      displayName: displayName,
      platform: platform
    )
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let session = sessionFactory(.spkiSHA256(invitation.serverSPKISHA256))
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw HarnessMonitorAPIError.invalidResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      throw HarnessMonitorAPIClient.decodeError(statusCode: response.statusCode, data: data)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let wire = try decoder.decode(RemoteDaemonPairingClaimResponse.self, from: data)
    guard
      wire.clientID == clientID,
      wire.displayName == displayName,
      wire.platform == platform,
      !wire.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw HarnessMonitorAPIError.invalidResponse
    }
    return RemoteDaemonPairingClaim(
      clientID: wire.clientID,
      displayName: wire.displayName,
      platform: wire.platform,
      role: wire.role,
      scopes: wire.scopes,
      token: wire.token,
      tokenHint: wire.tokenHint,
      pairedAt: wire.pairedAt
    )
  }
}

private struct RemoteDaemonPairingClaimRequest: Encodable {
  let code: String
  let domain: String
  let clientID: String
  let displayName: String
  let platform: String

  enum CodingKeys: String, CodingKey {
    case code
    case domain
    case clientID = "client_id"
    case displayName = "display_name"
    case platform
  }
}

private struct RemoteDaemonPairingClaimResponse: Decodable {
  let clientID: String
  let displayName: String
  let platform: String
  let role: RemoteDaemonRole
  let scopes: [String]
  let token: String
  let tokenHint: String
  let pairedAt: Date

  enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
    case displayName = "display_name"
    case platform
    case role
    case scopes
    case token
    case tokenHint = "token_hint"
    case pairedAt = "paired_at"
  }
}
