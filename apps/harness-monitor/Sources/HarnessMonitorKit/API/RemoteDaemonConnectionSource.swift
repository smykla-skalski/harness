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
      remoteClientID: profile.clientID,
      serverTrust: .spkiSHA256(profile.serverSPKISHA256),
      source: .remote(profileID: profile.id)
    )
  }

  public func markRevoked(profileID: UUID, at date: Date) throws {
    let originalState = try repository.load()
    guard let index = originalState.profiles.firstIndex(where: { $0.id == profileID }) else {
      throw RemoteDaemonProfileError.profileNotFound
    }
    let token = try? tokenStore.loadToken(profileID: profileID)
    var revokedState = originalState
    revokedState.profiles[index] = revokedState.profiles[index].markingRevoked(at: date)
    try tokenStore.deleteToken(profileID: profileID)
    do {
      try repository.save(revokedState)
    } catch {
      rollbackRevocation(state: originalState, token: token, profileID: profileID)
      throw error
    }
  }

  private func rollbackRevocation(
    state: RemoteDaemonProfileState,
    token: String?,
    profileID: UUID
  ) {
    try? repository.save(state)
    if let token {
      try? tokenStore.saveToken(token, profileID: profileID)
    }
  }
}
