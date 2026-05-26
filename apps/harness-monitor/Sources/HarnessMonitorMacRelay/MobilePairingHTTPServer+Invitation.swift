import Foundation
import HarnessMonitorCore

extension MobilePairingHTTPServer {
  /// Returns a still-valid pairing invitation, minting one on demand. The listener
  /// and its nonce are armed lazily here, so nothing is generated until a caller
  /// (the pairing settings panel) actually needs a code to show.
  public func ensureInvitation(
    invitationTTL: TimeInterval = 300
  ) async throws -> MobilePairingInvitation {
    if let cached = validCachedInvitation() {
      return cached
    }
    return try await refreshInvitation(invitationTTL: invitationTTL)
  }

  /// Always mints a fresh invitation (new nonce), starting the listener if it is
  /// not running yet and renewing against the live listener otherwise.
  public func refreshInvitation(
    invitationTTL: TimeInterval = 300
  ) async throws -> MobilePairingInvitation {
    do {
      return try await start(invitationTTL: invitationTTL)
    } catch MobilePairingHTTPServerError.alreadyRunning {
      return try await renewInvitation(invitationTTL: invitationTTL)
    }
  }
}
