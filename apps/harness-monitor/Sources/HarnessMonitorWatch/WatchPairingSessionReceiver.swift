import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import WatchConnectivity

final class WatchPairingSessionReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
  private static let transferKey = "io.harnessmonitor.mobile.watch-pairing-transfer"

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
    lock.lock()
    self.onCredentialsChanged = onCredentialsChanged
    guard !didStart else {
      lock.unlock()
      return
    }
    didStart = true
    lock.unlock()

    session?.delegate = self
    session?.activate()
  }

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: (any Error)?
  ) {}

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

  private func handlePayload(_ payload: [String: Any]) {
    guard let data = payload[Self.transferKey] as? Data,
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
      }
      let currentCredentials = try await credentialStore.loadAll()
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

  private func currentOnCredentialsChanged() -> (@MainActor @Sendable () async -> Void)? {
    lock.lock()
    let onCredentialsChanged = self.onCredentialsChanged
    lock.unlock()
    return onCredentialsChanged
  }
}
