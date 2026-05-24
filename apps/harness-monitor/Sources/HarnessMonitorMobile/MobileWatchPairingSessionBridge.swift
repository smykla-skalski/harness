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
  private static let transferKey = "io.harnessmonitor.mobile.watch-pairing-transfer"

  private let session: WCSession?
  private let lock = NSLock()
  private var pendingPayload: [String: Any]?

  override init() {
    session = WCSession.isSupported() ? WCSession.default : nil
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
    let payload = [Self.transferKey: data]
    setPendingPayload(payload)

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

  func sessionDidBecomeInactive(_ session: WCSession) {}

  func sessionDidDeactivate(_ session: WCSession) {
    session.activate()
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

  private func clearPendingPayload(matching payload: [String: Any]) {
    lock.lock()
    if NSDictionary(dictionary: pendingPayload ?? [:]).isEqual(to: payload) {
      pendingPayload = nil
    }
    lock.unlock()
  }
}
