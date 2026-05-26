import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto

/// Pairs a Mac from an invitation URL, returning the station credential. The
/// live implementation lives in the iOS target.
public protocol MobileMonitorCredentialPairer: Sendable {
  func pair(
    invitationURL: URL,
    deviceName: String,
    now: Date
  ) async throws -> MobilePairedStationCredential
}

/// Reconciles command Live Activities against the latest snapshot. The live
/// implementation (ActivityKit) lives in the iOS target; the watch omits it.
@MainActor
public protocol MobileCommandLiveActivityCoordinating: Sendable {
  func reconcile(
    snapshot: MobileMirrorSnapshot,
    preferredStationID: String?,
    now: Date
  ) async
}

extension MobileCommandLiveActivityCoordinating {
  public func reconcile(
    snapshot: MobileMirrorSnapshot,
    preferredStationID: String?
  ) async {
    await reconcile(snapshot: snapshot, preferredStationID: preferredStationID, now: .now)
  }
}

/// Schedules local notifications for mirror events. The live implementation
/// (UserNotifications) lives in the iOS target; the watch omits it.
public protocol MobileNotificationScheduling: Sendable {
  func requestAuthorization() async -> Bool
  func schedule(_ requests: [MobileNotificationRequest]) async -> Set<String>
}

/// Publishes pairing material to the watch. The live implementation
/// (WatchConnectivity) lives in the iOS target; the watch omits it.
public protocol MobileWatchPairingSyncing: Sendable {
  func publish(
    identities: [MobileDeviceIdentity],
    credentials: [MobilePairedStationCredential],
    snapshot: MobileMirrorSnapshot?,
    exportedAt: Date
  ) async
}
