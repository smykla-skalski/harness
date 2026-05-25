import Foundation

extension HarnessMonitorStore {
  public func clientForMobileRelay() async throws -> any HarnessMonitorClientProtocol {
    if let client {
      return client
    }
    if let mobileRelayBackgroundClient {
      return mobileRelayBackgroundClient
    }

    let client = try await makeMobileRelayBackgroundClient()
    mobileRelayBackgroundClient = client
    return client
  }

  private func makeMobileRelayBackgroundClient() async throws -> any HarnessMonitorClientProtocol {
    switch daemonOwnership {
    case .managed:
      let registrationState = try await ensureManagedLaunchAgentReady()
      guard registrationState == .enabled else {
        throw DaemonControlError.commandFailed(
          "Mobile relay needs the managed daemon launch agent to be enabled."
        )
      }
      return try await awaitManagedDaemonWarmUpWithRecovery()
    case .external:
      return try await daemonController.awaitManifestWarmUp(timeout: bootstrapWarmUpTimeout)
    }
  }

  public func invalidateMobileRelayBackgroundClient(reason: String) async {
    guard let client = mobileRelayBackgroundClient else {
      return
    }
    HarnessMonitorLogger.store.info(
      "Invalidating mobile relay background daemon client after failure: \(reason, privacy: .public)"
    )
    mobileRelayBackgroundClient = nil
    await client.shutdown()
  }

  func shutdownMobileRelayBackgroundClient() async {
    guard let client = mobileRelayBackgroundClient else {
      return
    }
    mobileRelayBackgroundClient = nil
    await client.shutdown()
  }
}
