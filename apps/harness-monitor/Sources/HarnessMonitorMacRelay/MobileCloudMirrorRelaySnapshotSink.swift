import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto

public actor MobileCloudMirrorRelaySnapshotSink: MobileMirrorSnapshotSink {
  private let stationID: String
  private let writer: MobileCloudMirrorSnapshotWriter
  private let trustedDeviceStore: any MobilePairingTrustedDeviceStore
  private let now: @Sendable () -> Date

  public init(
    stationID: String,
    writer: MobileCloudMirrorSnapshotWriter,
    trustedDeviceStore: any MobilePairingTrustedDeviceStore,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.stationID = stationID
    self.writer = writer
    self.trustedDeviceStore = trustedDeviceStore
    self.now = now
  }

  public func writeSnapshot(_ snapshot: MobileMirrorSnapshot) async throws {
    let devices = try await trustedDeviceStore.trustedDevices()
    _ = try await writer.writeSnapshot(
      snapshot,
      stationID: stationID,
      devices: devices,
      now: now()
    )
  }
}
