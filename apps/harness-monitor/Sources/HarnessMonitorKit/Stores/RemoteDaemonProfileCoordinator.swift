import Foundation

public actor RemoteDaemonProfileCoordinator {
  private let repository: any RemoteDaemonProfilePersisting
  private let tokenStore: any RemoteDaemonTokenPersisting
  private let claimant: any RemoteDaemonPairingClaiming
  private let revoker: any RemoteDaemonClientRevoking
  private let profileIDGenerator: @Sendable () -> UUID
  private let clientIDGenerator: @Sendable (UUID) -> String

  public init(
    repository: any RemoteDaemonProfilePersisting,
    tokenStore: any RemoteDaemonTokenPersisting,
    claimant: any RemoteDaemonPairingClaiming = HTTPRemoteDaemonPairingClient(),
    revoker: any RemoteDaemonClientRevoking = HTTPRemoteDaemonRevocationClient(),
    profileIDGenerator: @escaping @Sendable () -> UUID = UUID.init,
    clientIDGenerator: @escaping @Sendable (UUID) -> String = {
      "macos-\($0.uuidString.lowercased())"
    }
  ) {
    self.repository = repository
    self.tokenStore = tokenStore
    self.claimant = claimant
    self.revoker = revoker
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
    try activate(profile, token: claim.token)
    return profile
  }

  @discardableResult
  public func forgetActiveProfile() async throws -> RemoteDaemonProfile? {
    let originalState = try repository.load()
    guard let activeProfileID = originalState.activeProfileID else {
      return nil
    }
    guard let profile = originalState.profiles.first(where: { $0.id == activeProfileID }) else {
      throw RemoteDaemonProfileError.profileNotFound
    }
    let token = try tokenForForget(profile)
    if profile.status == .active {
      guard let token else {
        throw RemoteDaemonProfileError.missingToken
      }
      try await revoker.revoke(profile: profile, token: token)
    }
    var forgottenState = originalState
    forgottenState.profiles.removeAll { $0.id == activeProfileID }
    forgottenState.activeProfileID = nil
    do {
      try tokenStore.deleteToken(profileID: activeProfileID)
    } catch {
      restoreToken(token, profileID: activeProfileID)
      throw error
    }
    do {
      try repository.save(forgottenState)
    } catch {
      rollbackForget(state: originalState, token: token, profileID: activeProfileID)
      throw error
    }
    return profile
  }

  private func tokenForForget(_ profile: RemoteDaemonProfile) throws -> String? {
    if profile.status == .revoked {
      return try? tokenStore.loadToken(profileID: profile.id)
    }
    guard let token = try tokenStore.loadToken(profileID: profile.id),
      !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw RemoteDaemonProfileError.missingToken
    }
    return token
  }

  private func activate(_ profile: RemoteDaemonProfile, token: String) throws {
    let originalState = try repository.load()
    let replacedProfiles = originalState.profiles.filter {
      $0.id == profile.id || $0.clientID == profile.clientID
    }
    let replacedTokens = replacedProfiles.map { replacedProfile in
      (
        profileID: replacedProfile.id,
        token: try? tokenStore.loadToken(profileID: replacedProfile.id)
      )
    }
    var activatedState = originalState
    activatedState.profiles.removeAll {
      $0.id == profile.id || $0.clientID == profile.clientID
    }
    activatedState.profiles.append(profile)
    activatedState.activeProfileID = profile.id

    do {
      try tokenStore.saveToken(token, profileID: profile.id)
      for replacedProfile in replacedProfiles where replacedProfile.id != profile.id {
        try tokenStore.deleteToken(profileID: replacedProfile.id)
      }
      try repository.save(activatedState)
    } catch {
      try? tokenStore.deleteToken(profileID: profile.id)
      restoreReplacedTokens(replacedTokens)
      throw error
    }
  }

  private func restoreReplacedTokens(_ replacedTokens: [(profileID: UUID, token: String?)]) {
    for replacedToken in replacedTokens {
      if let token = replacedToken.token {
        try? tokenStore.saveToken(token, profileID: replacedToken.profileID)
      } else {
        try? tokenStore.deleteToken(profileID: replacedToken.profileID)
      }
    }
  }

  private func rollbackForget(
    state: RemoteDaemonProfileState,
    token: String?,
    profileID: UUID
  ) {
    try? repository.save(state)
    restoreToken(token, profileID: profileID)
  }

  private func restoreToken(_ token: String?, profileID: UUID) {
    if let token {
      try? tokenStore.saveToken(token, profileID: profileID)
    }
  }
}
