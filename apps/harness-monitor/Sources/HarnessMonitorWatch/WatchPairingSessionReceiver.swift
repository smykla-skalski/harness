import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import WatchConnectivity
import WidgetKit

final class WatchPairingSessionReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
  private let session: WCSession?
  private let identityStore: any MobileDeviceIdentityStore
  private let credentialStore: any MobilePairedStationCredentialStore
  private let sharedSnapshotStore: MobileSharedSnapshotStore?
  private let lock = NSLock()
  private var didStart = false
  private var onCredentialsChanged: (@MainActor @Sendable () async -> Void)?

  init(
    identityStore: any MobileDeviceIdentityStore,
    credentialStore: any MobilePairedStationCredentialStore,
    sharedSnapshotStore: MobileSharedSnapshotStore? = MobileSharedSnapshotStore()
  ) {
    session = WCSession.isSupported() ? WCSession.default : nil
    self.identityStore = identityStore
    self.credentialStore = credentialStore
    self.sharedSnapshotStore = sharedSnapshotStore
    super.init()
  }

  func start(onCredentialsChanged: @escaping @MainActor @Sendable () async -> Void) {
    let shouldStartSession: Bool
    lock.lock()
    self.onCredentialsChanged = onCredentialsChanged
    shouldStartSession = !didStart
    if shouldStartSession {
      didStart = true
    }
    lock.unlock()

    if shouldStartSession {
      session?.delegate = self
      session?.activate()
    }
    if session?.activationState == .activated {
      handlePayload(session?.receivedApplicationContext ?? [:])
      requestPairingTransfer()
    }
  }

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: (any Error)?
  ) {
    guard activationState == .activated, error == nil else {
      return
    }
    handlePayload(session.receivedApplicationContext)
    requestPairingTransfer()
  }

  func session(
    _ session: WCSession,
    didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    handlePayload(applicationContext)
  }

  func session(
    _ session: WCSession,
    didReceiveUserInfo userInfo: [String: Any]
  ) {
    handlePayload(userInfo)
  }

  func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any]
  ) {
    handlePayload(message)
  }

  func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    handlePayload(message)
    replyHandler([:])
  }

  func requestPairingTransfer() {
    guard let session, session.activationState == .activated else {
      return
    }
    let payload: [String: Any] = [
      MobileWatchPairingTransferEnvelope.requestKey: true,
      "requestedAt": Date().timeIntervalSince1970,
    ]
    if session.isReachable {
      session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
    }
    do {
      try session.updateApplicationContext(payload)
    } catch {
      // The user-info transfer below is still durable when immediate context fails.
    }
    session.transferUserInfo(payload)
  }

  private func handlePayload(_ payload: [String: Any]) {
    guard let data = payload[MobileWatchPairingTransferEnvelope.transferKey] as? Data,
      let transfer = try? MobileWatchPairingTransfer.decode(data)
    else {
      return
    }
    Task {
      await save(transfer)
    }
  }

  private func save(_ transfer: MobileWatchPairingTransfer) async {
    do {
      if let snapshot = transfer.snapshot {
        try sharedSnapshotStore?.save(snapshot, savedAt: transfer.exportedAt)
        WidgetCenter.shared.reloadAllTimelines()
      }
      let currentCredentials = try await credentialStore.loadAll()
      let currentIdentities = try await loadIdentities(
        for: Set(currentCredentials.map(\.deviceIdentityID))
      )
      guard
        transfer.changesPairingMaterial(
          currentIdentities: currentIdentities,
          currentCredentials: currentCredentials
        )
      else {
        // The iPhone re-sends the same pairing material with every relayed snapshot.
        // Reloading here would reset the watch to "Syncing" and restart its refresh on
        // every push, so a snapshot-only update stops at the cache save above.
        return
      }
      let replacementPlan = transfer.replacementPlan(replacing: currentCredentials)
      for stationID in replacementPlan.credentialStationIDsToDelete {
        try await credentialStore.delete(stationID: stationID)
      }
      for identityID in replacementPlan.identityIDsToDelete {
        try await identityStore.delete(id: identityID)
      }
      for identity in transfer.identities {
        try await identityStore.save(identity)
      }
      for credential in transfer.credentials {
        try await credentialStore.save(credential)
      }
      let onCredentialsChanged = currentOnCredentialsChanged()
      if let onCredentialsChanged {
        await onCredentialsChanged()
      }
    } catch {
      // Watch can keep its last known credentials; the next iPhone sync retries this payload.
    }
  }

  private func loadIdentities(for ids: Set<String>) async throws -> [MobileDeviceIdentity] {
    var identities: [MobileDeviceIdentity] = []
    for id in ids {
      if let identity = try await identityStore.load(id: id) {
        identities.append(identity)
      }
    }
    return identities
  }

  private func currentOnCredentialsChanged() -> (@MainActor @Sendable () async -> Void)? {
    lock.lock()
    let onCredentialsChanged = self.onCredentialsChanged
    lock.unlock()
    return onCredentialsChanged
  }
}
