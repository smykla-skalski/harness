import Foundation
import XCTest

@testable import HarnessMonitor
import HarnessMonitorKit
import HarnessMonitorUIPreviewable

extension HarnessMonitorAppConfigurationTests {
  func testMobileRelayStorageMigratesTrustedLaneStateWhenStableRootHasNoDevices() throws {
    let fileManager = FileManager.default
    let home = fileManager.temporaryDirectory
      .appendingPathComponent("harness-monitor-mobile-relay-migration-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: home) }
    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorRuntimeLane.environmentKey: "lane-a"],
      homeDirectory: home
    )
    let stableRoot = MobileRelayStorageResolver.storageRoot(environment: environment)
    let laneRoot =
      home
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Group Containers", isDirectory: true)
      .appendingPathComponent(HarnessMonitorAppGroup.identifier, isDirectory: true)
      .appendingPathComponent(HarnessMonitorRuntimeLane.dataHomeLanesDirectoryName, isDirectory: true)
      .appendingPathComponent("lane-a", isDirectory: true)
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("mobile-relay", isDirectory: true)

    try writeMobileRelayState(
      stationID: "station-empty",
      trustedDeviceIDs: [],
      to: stableRoot,
      fileManager: fileManager
    )
    try writeMobileRelayState(
      stationID: "station-paired",
      trustedDeviceIDs: ["device-phone"],
      to: laneRoot,
      fileManager: fileManager
    )

    let preparedRoot = MobileRelayStorageResolver.prepareStorageRoot(
      environment: environment,
      fileManager: fileManager
    )
    let stationIdentityData = try Data(
      contentsOf: preparedRoot.appendingPathComponent("station-identity.json")
    )
    let trustedDevicesData = try Data(
      contentsOf: preparedRoot.appendingPathComponent("trusted-mobile-devices.json")
    )
    let stationIdentity = try XCTUnwrap(
      JSONSerialization.jsonObject(with: stationIdentityData) as? [String: Any]
    )
    let trustedDevices = try XCTUnwrap(
      JSONSerialization.jsonObject(with: trustedDevicesData) as? [[String: Any]]
    )

    XCTAssertEqual(preparedRoot, stableRoot)
    XCTAssertEqual(stationIdentity["stationID"] as? String, "station-paired")
    XCTAssertEqual(trustedDevices.count, 1)
    XCTAssertEqual(trustedDevices.first?["deviceID"] as? String, "device-phone")
  }

  func testMobileRelayStorageMigratesWhenStableDevicesUseDifferentStation() throws {
    let fileManager = FileManager.default
    let home = fileManager.temporaryDirectory
      .appendingPathComponent("harness-monitor-mobile-relay-mismatched-station-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: home) }
    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorRuntimeLane.environmentKey: "lane-a"],
      homeDirectory: home
    )
    let stableRoot = MobileRelayStorageResolver.storageRoot(environment: environment)
    let laneRoot =
      home
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Group Containers", isDirectory: true)
      .appendingPathComponent(HarnessMonitorAppGroup.identifier, isDirectory: true)
      .appendingPathComponent(HarnessMonitorRuntimeLane.dataHomeLanesDirectoryName, isDirectory: true)
      .appendingPathComponent("lane-a", isDirectory: true)
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("mobile-relay", isDirectory: true)

    try writeMobileRelayState(
      stationID: "station-new",
      trustedDeviceIDs: ["device-phone"],
      trustedDeviceStationID: "station-old",
      to: stableRoot,
      fileManager: fileManager
    )
    try writeMobileRelayState(
      stationID: "station-old",
      trustedDeviceIDs: ["device-phone"],
      to: laneRoot,
      fileManager: fileManager
    )

    let preparedRoot = MobileRelayStorageResolver.prepareStorageRoot(
      environment: environment,
      fileManager: fileManager
    )
    let stationIdentityData = try Data(
      contentsOf: preparedRoot.appendingPathComponent("station-identity.json")
    )
    let trustedDevicesData = try Data(
      contentsOf: preparedRoot.appendingPathComponent("trusted-mobile-devices.json")
    )
    let stationIdentity = try XCTUnwrap(
      JSONSerialization.jsonObject(with: stationIdentityData) as? [String: Any]
    )
    let trustedDevices = try XCTUnwrap(
      JSONSerialization.jsonObject(with: trustedDevicesData) as? [[String: Any]]
    )

    XCTAssertEqual(preparedRoot, stableRoot)
    XCTAssertEqual(stationIdentity["stationID"] as? String, "station-old")
    XCTAssertEqual(trustedDevices.first?["stationID"] as? String, "station-old")
  }

  private func writeMobileRelayState(
    stationID: String,
    trustedDeviceIDs: [String],
    trustedDeviceStationID: String? = nil,
    to root: URL,
    fileManager: FileManager
  ) throws {
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let stationIdentity: [String: Any] = [
      "stationID": stationID,
      "stationName": "Mac",
    ]
    let trustedDevices = trustedDeviceIDs.map { deviceID in
      [
        "deviceID": deviceID,
        "stationID": trustedDeviceStationID ?? stationID,
      ]
    }
    try JSONSerialization.data(withJSONObject: stationIdentity)
      .write(to: root.appendingPathComponent("station-identity.json"))
    try JSONSerialization.data(withJSONObject: trustedDevices)
      .write(to: root.appendingPathComponent("trusted-mobile-devices.json"))
  }
}
