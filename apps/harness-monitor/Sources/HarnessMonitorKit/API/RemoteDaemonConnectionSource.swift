import Foundation

public protocol RemoteDaemonConnectionSourcing: Sendable {
  func activeConnection() throws -> HarnessMonitorConnection?
  func activeProfile() throws -> RemoteDaemonProfile?
  func markRevoked(profileID: UUID, at date: Date) throws
}

struct DisabledRemoteDaemonConnectionSource: RemoteDaemonConnectionSourcing {
  func activeConnection() throws -> HarnessMonitorConnection? { nil }
  func activeProfile() throws -> RemoteDaemonProfile? { nil }

  func markRevoked(profileID: UUID, at date: Date) throws {
    throw RemoteDaemonProfileError.profileNotFound
  }
}

public struct StoredRemoteDaemonConnectionSource: RemoteDaemonConnectionSourcing, Sendable {
  private let repository: any RemoteDaemonProfilePersisting
  private let tokenStore: any RemoteDaemonTokenPersisting

  public init(
    repository: any RemoteDaemonProfilePersisting,
    tokenStore: any RemoteDaemonTokenPersisting
  ) {
    self.repository = repository
    self.tokenStore = tokenStore
  }

  public func activeProfile() throws -> RemoteDaemonProfile? {
    let state = try repository.load()
    guard let activeProfileID = state.activeProfileID else {
      return nil
    }
    guard let profile = state.profiles.first(where: { $0.id == activeProfileID }) else {
      throw RemoteDaemonProfileError.profileNotFound
    }
    return profile
  }

  public func activeConnection() throws -> HarnessMonitorConnection? {
    guard let profile = try activeProfile() else {
      return nil
    }
    guard profile.status == .active else {
      throw RemoteDaemonProfileError.revoked
    }
    guard
      let token = try tokenStore.loadToken(profileID: profile.id)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    else {
      throw RemoteDaemonProfileError.missingToken
    }
    return HarnessMonitorConnection(
      endpoint: profile.endpoint,
      token: token,
      serverTrust: .spkiSHA256(profile.serverSPKISHA256),
      source: .remote(profileID: profile.id)
    )
  }

  public func markRevoked(profileID: UUID, at date: Date) throws {
    var state = try repository.load()
    guard let index = state.profiles.firstIndex(where: { $0.id == profileID }) else {
      throw RemoteDaemonProfileError.profileNotFound
    }
    state.profiles[index] = state.profiles[index].markingRevoked(at: date)
    try repository.save(state)
    try tokenStore.deleteToken(profileID: profileID)
  }
}
