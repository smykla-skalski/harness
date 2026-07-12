import Foundation

public enum RemoteDaemonActionState: Equatable, Sendable {
  case idle
  case pairing
  case forgetting
  case failed(String)

  public var errorMessage: String? {
    guard case .failed(let message) = self else {
      return nil
    }
    return message
  }

  public var isInFlight: Bool {
    self == .pairing || self == .forgetting
  }
}

extension HarnessMonitorStore {
  var remoteDaemonServices: RemoteDaemonServices? {
    connection.remoteDaemonServices
  }

  public internal(set) var remoteDaemonProfile: RemoteDaemonProfile? {
    get { connection.remoteDaemonProfile }
    set { connection.remoteDaemonProfile = newValue }
  }

  public internal(set) var remoteDaemonActionState: RemoteDaemonActionState {
    get { connection.remoteDaemonActionState }
    set { connection.remoteDaemonActionState = newValue }
  }

  public var usesRemoteDaemon: Bool {
    remoteDaemonProfile != nil
  }

  public func pairRemoteDaemon(
    using input: RemoteDaemonPairingInput,
    displayName: String
  ) {
    guard !remoteDaemonActionState.isInFlight else { return }
    guard let remoteDaemonServices else {
      remoteDaemonActionState = .failed("Remote daemon pairing is unavailable")
      return
    }
    let displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !displayName.isEmpty else {
      remoteDaemonActionState = .failed("A client name is required")
      return
    }
    remoteDaemonActionState = .pairing
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Pair remote daemon") { [weak self] in
        do {
          let invitation = try input.invitation()
          let profile = try await remoteDaemonServices.profileCoordinator.pair(
            invitation: invitation,
            displayName: displayName
          )
          await self?.completeRemoteDaemonPairing(profile)
        } catch {
          await self?.failRemoteDaemonAction(error)
        }
      }
    )
  }

  public func forgetRemoteDaemon() {
    guard !remoteDaemonActionState.isInFlight else { return }
    guard let remoteDaemonServices else {
      remoteDaemonActionState = .failed("Remote daemon profiles are unavailable")
      return
    }
    remoteDaemonActionState = .forgetting
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Forget remote daemon") { [weak self] in
        do {
          _ = try await remoteDaemonServices.profileCoordinator.forgetActiveProfile()
          await self?.completeRemoteDaemonForget()
        } catch {
          await self?.failRemoteDaemonAction(error)
        }
      }
    )
  }

  func refreshRemoteDaemonProfile() {
    guard let remoteDaemonServices else {
      remoteDaemonProfile = nil
      return
    }
    do {
      remoteDaemonProfile = try remoteDaemonServices.connectionSource.activeProfile()
    } catch {
      remoteDaemonProfile = nil
      remoteDaemonActionState = .failed(error.localizedDescription)
    }
  }

  func handleRemoteDaemonConnectionFailure(_ error: any Error) {
    guard let remoteDaemonServices else {
      return
    }
    refreshRemoteDaemonProfile()
    guard
      remoteDaemonProfile?.status == .active,
      let apiError = error as? HarnessMonitorAPIError,
      case .server(let code, _) = apiError,
      code == 401,
      let profileID = remoteDaemonProfile?.id
    else {
      return
    }
    do {
      try remoteDaemonServices.connectionSource.markRevoked(profileID: profileID, at: .now)
      refreshRemoteDaemonProfile()
    } catch {
      remoteDaemonActionState = .failed(error.localizedDescription)
    }
  }

  private func completeRemoteDaemonPairing(_ profile: RemoteDaemonProfile) async {
    remoteDaemonProfile = profile
    remoteDaemonActionState = .idle
    await reconnect()
  }

  private func completeRemoteDaemonForget() async {
    remoteDaemonProfile = nil
    remoteDaemonActionState = .idle
    resetLocalManifestURL()
    await reconnect()
  }

  private func failRemoteDaemonAction(_ error: any Error) {
    remoteDaemonActionState = .failed(error.localizedDescription)
  }
}
