import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import WatchConnectivity

protocol MobileWatchPairingSyncing: Sendable {
  func publish(
    identities: [MobileDeviceIdentity],
    credentials: [MobilePairedStationCredential],
    snapshot: MobileMirrorSnapshot?,
    exportedAt: Date
  ) async
}

final class MobileWatchPairingSessionBridge: NSObject, MobileWatchPairingSyncing,
  WCSessionDelegate, @unchecked Sendable
{
  private let session: WCSession?
  private let identityStore: (any MobileDeviceIdentityStore)?
  private let credentialStore: (any MobilePairedStationCredentialStore)?
  private let sharedSnapshotStore: MobileSharedSnapshotStore?
  private let lock = NSLock()
  private var pendingPayload: [String: Any]?
  private var lastPayload: [String: Any]?

  init(
    identityStore: (any MobileDeviceIdentityStore)? = nil,
    credentialStore: (any MobilePairedStationCredentialStore)? = nil,
    sharedSnapshotStore: MobileSharedSnapshotStore? = MobileSharedSnapshotStore()
  ) {
    session = WCSession.isSupported() ? WCSession.default : nil
    self.identityStore = identityStore
    self.credentialStore = credentialStore
    self.sharedSnapshotStore = sharedSnapshotStore
    super.init()
    session?.delegate = self
    session?.activate()
  }

  func publish(
    identities: [MobileDeviceIdentity],
    credentials: [MobilePairedStationCredential],
    snapshot: MobileMirrorSnapshot? = nil,
    exportedAt: Date = .now
  ) async {
    let transfer = MobileWatchPairingTransfer(
      identities: identities,
      credentials: credentials,
      snapshot: snapshot,
      exportedAt: exportedAt
    )
    guard let data = try? transfer.encodedData() else {
      return
    }
    let payload = [MobileWatchPairingTransferEnvelope.transferKey: data]
    cachePayloadForTransfer(payload)

    guard let session else {
      return
    }
    session.activate()
    flushPendingPayloadIfReady()
  }

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: (any Error)?
  ) {
    guard activationState == .activated, error == nil else {
      return
    }
    flushPendingPayloadIfReady()
  }

  func sessionWatchStateDidChange(_ session: WCSession) {
    flushPendingPayloadIfReady()
  }

  func sessionReachabilityDidChange(_ session: WCSession) {
    flushPendingPayloadIfReady()
  }

  func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any]
  ) {
    handleWatchPairingRequest(message)
  }

  func session(
    _ session: WCSession,
    didReceiveUserInfo userInfo: [String: Any]
  ) {
    handleWatchPairingRequest(userInfo)
  }

  func session(
    _ session: WCSession,
    didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    handleWatchPairingRequest(applicationContext)
  }

  func sessionDidBecomeInactive(_ session: WCSession) {}

  func sessionDidDeactivate(_ session: WCSession) {
    session.activate()
  }

  private func handleWatchPairingRequest(_ payload: [String: Any]) {
    guard payload[MobileWatchPairingTransferEnvelope.requestKey] as? Bool == true else {
      return
    }
    if let payload = currentLastPayload() {
      setPendingPayload(payload)
      flushPendingPayloadIfReady()
      return
    }
    Task {
      await publishStoredPairingsForWatchRequest()
    }
  }

  private func publishStoredPairingsForWatchRequest() async {
    guard let identityStore, let credentialStore else {
      return
    }
    do {
      let credentials = try await credentialStore.loadAll()
      var validCredentials: [MobilePairedStationCredential] = []
      var identitiesByID: [String: MobileDeviceIdentity] = [:]
      for credential in credentials {
        guard let identity = try await identityStore.load(id: credential.deviceIdentityID) else {
          continue
        }
        validCredentials.append(credential)
        identitiesByID[identity.id] = identity
      }
      let snapshot = try? sharedSnapshotStore?.loadSnapshot()
      await publish(
        identities: identitiesByID.values.sorted { $0.id < $1.id },
        credentials: validCredentials,
        snapshot: snapshot,
        exportedAt: .now
      )
    } catch {
      // The next foreground sync publishes the same pairing payload again.
    }
  }

  private func flushPendingPayloadIfReady() {
    guard let session,
      session.activationState == .activated,
      session.isPaired,
      session.isWatchAppInstalled
    else {
      return
    }
    guard let payload = currentPendingPayload() else {
      return
    }

    do {
      try session.updateApplicationContext(payload)
      session.transferUserInfo(payload)
      clearPendingPayload(matching: payload)
    } catch {
      setPendingPayload(payload)
    }
  }

  private func cachePayloadForTransfer(_ payload: [String: Any]) {
    lock.lock()
    pendingPayload = payload
    lastPayload = payload
    lock.unlock()
  }

  private func setPendingPayload(_ payload: [String: Any]) {
    lock.lock()
    pendingPayload = payload
    lock.unlock()
  }

  private func currentPendingPayload() -> [String: Any]? {
    lock.lock()
    let payload = pendingPayload
    lock.unlock()
    return payload
  }

  private func currentLastPayload() -> [String: Any]? {
    lock.lock()
    let payload = lastPayload
    lock.unlock()
    return payload
  }

  private func clearPendingPayload(matching payload: [String: Any]) {
    lock.lock()
    if NSDictionary(dictionary: pendingPayload ?? [:]).isEqual(to: payload) {
      pendingPayload = nil
    }
    lock.unlock()
  }
}
