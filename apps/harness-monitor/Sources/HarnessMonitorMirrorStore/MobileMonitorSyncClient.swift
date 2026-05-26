import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto

/// The mobile sync operations the shared store depends on. Kept as a protocol
/// so tests can inject fakes; the live implementation is the CloudMirror sync
/// client, which conforms directly below.
public protocol MobileMonitorSyncClient: Sendable {
  func fetchLatestSnapshot(stationID: String, now: Date) async throws -> MobileMirrorSnapshot?
  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileQueuedCommand
  func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt
}

extension MobileCloudMirrorSyncClient: MobileMonitorSyncClient {}

public protocol MobileMonitorSyncClientFactory: Sendable {
  func makeSyncClient(
    credential: MobilePairedStationCredential,
    identity: MobileDeviceIdentity
  ) -> any MobileMonitorSyncClient
}

/// Builds live CloudMirror sync clients. The optional `actorDeviceID` transform
/// lets the watch stamp commands with its own actor id; the phone leaves it nil
/// so the client falls back to the device identity id.
public struct LiveMobileMonitorSyncClientFactory: MobileMonitorSyncClientFactory {
  private let actorDeviceID: @Sendable (MobileDeviceIdentity) -> String?

  public init(
    actorDeviceID: @escaping @Sendable (MobileDeviceIdentity) -> String? = { _ in nil }
  ) {
    self.actorDeviceID = actorDeviceID
  }

  public func makeSyncClient(
    credential: MobilePairedStationCredential,
    identity: MobileDeviceIdentity
  ) -> any MobileMonitorSyncClient {
    MobileCloudMirrorSyncClient(
      database: LiveMobileCloudMirrorDatabase(),
      cipher: MobilePayloadCipher(rawKey: credential.symmetricKeyRawRepresentation),
      deviceIdentity: identity,
      actorDeviceID: actorDeviceID(identity),
      commandKeyID: credential.commandKeyID
    )
  }
}
