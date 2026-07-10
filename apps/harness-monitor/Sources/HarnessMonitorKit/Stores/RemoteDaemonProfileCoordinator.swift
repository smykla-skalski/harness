import Foundation

public actor RemoteDaemonProfileCoordinator {
  private let repository: any RemoteDaemonProfilePersisting
  private let tokenStore: any RemoteDaemonTokenPersisting
  private let claimant: any RemoteDaemonPairingClaiming
  private let profileIDGenerator: @Sendable () -> UUID
  private let clientIDGenerator: @Sendable (UUID) -> String

  public init(
    repository: any RemoteDaemonProfilePersisting,
    tokenStore: any RemoteDaemonTokenPersisting,
    claimant: any RemoteDaemonPairingClaiming = HTTPRemoteDaemonPairingClient(),
    profileIDGenerator: @escaping @Sendable () -> UUID = UUID.init,
    clientIDGenerator: @escaping @Sendable (UUID) -> String = {
      "macos-\($0.uuidString.lowercased())"
    }
  ) {
    self.repository = repository
    self.tokenStore = tokenStore
    self.claimant = claimant
    self.profileIDGenerator = profileIDGenerator
    self.clientIDGenerator = clientIDGenerator
  }

  public func pair(
    invitation: RemoteDaemonPairingInvitation,
    displayName: String
  ) async throws -> RemoteDaemonProfile {
    let profileID = profileIDGenerator()
    let clientID = clientIDGenerator(profileID)
    let claim = try await claimant.claim(
      invitation: invitation,
      clientID: clientID,
      displayName: displayName,
      platform: "macos"
    )
    guard claim.clientID == clientID else {
      throw HarnessMonitorAPIError.invalidResponse
    }
    let profile = RemoteDaemonProfile(
      id: profileID,
      endpoint: invitation.endpoint,
      clientID: claim.clientID,
      displayName: claim.displayName,
      platform: claim.platform,
      role: claim.role,
      scopes: claim.scopes,
      serverSPKISHA256: invitation.serverSPKISHA256,
      tokenHint: claim.tokenHint,
      pairedAt: claim.pairedAt,
      pairingExpiresAt: invitation.expiresAt,
      status: .active,
      revokedAt: nil
    )
    _ = try profile.validated()
    try tokenStore.saveToken(claim.token, profileID: profileID)
    do {
      var state = try repository.load()
      state.profiles.removeAll { $0.id == profileID || $0.clientID == claim.clientID }
      state.profiles.append(profile)
      state.activeProfileID = profileID
      try repository.save(state)
    } catch {
      try? tokenStore.deleteToken(profileID: profileID)
      throw error
    }
    return profile
  }

  @discardableResult
  public func forgetActiveProfile() throws -> RemoteDaemonProfile? {
    var state = try repository.load()
    guard let activeProfileID = state.activeProfileID else {
      return nil
    }
    guard let profile = state.profiles.first(where: { $0.id == activeProfileID }) else {
      throw RemoteDaemonProfileError.profileNotFound
    }
    state.profiles.removeAll { $0.id == activeProfileID }
    state.activeProfileID = nil
    try repository.save(state)
    try tokenStore.deleteToken(profileID: activeProfileID)
    return profile
  }
}
