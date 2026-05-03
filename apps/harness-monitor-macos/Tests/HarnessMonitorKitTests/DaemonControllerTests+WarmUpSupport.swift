import Foundation

@testable import HarnessMonitorKit

struct ManagedLaunchAgentBundleStampFixture: Codable {
  let helperPath: String
  let deviceIdentifier: UInt64
  let inode: UInt64
  let fileSize: UInt64
  let modificationTimeIntervalSince1970: Double
  let launchAgentPlistPath: String?
  let launchAgentPlistDeviceIdentifier: UInt64?
  let launchAgentPlistInode: UInt64?
  let launchAgentPlistFileSize: UInt64?
  let launchAgentPlistModificationTimeIntervalSince1970: Double?

  init(
    helperPath: String,
    deviceIdentifier: UInt64,
    inode: UInt64,
    fileSize: UInt64,
    modificationTimeIntervalSince1970: Double,
    launchAgentPlistPath: String? = nil,
    launchAgentPlistDeviceIdentifier: UInt64? = nil,
    launchAgentPlistInode: UInt64? = nil,
    launchAgentPlistFileSize: UInt64? = nil,
    launchAgentPlistModificationTimeIntervalSince1970: Double? = nil
  ) {
    self.helperPath = helperPath
    self.deviceIdentifier = deviceIdentifier
    self.inode = inode
    self.fileSize = fileSize
    self.modificationTimeIntervalSince1970 = modificationTimeIntervalSince1970
    self.launchAgentPlistPath = launchAgentPlistPath
    self.launchAgentPlistDeviceIdentifier = launchAgentPlistDeviceIdentifier
    self.launchAgentPlistInode = launchAgentPlistInode
    self.launchAgentPlistFileSize = launchAgentPlistFileSize
    self.launchAgentPlistModificationTimeIntervalSince1970 =
      launchAgentPlistModificationTimeIntervalSince1970
  }
}

extension ManagedLaunchAgentBundleStampFixture {
  var managedLaunchAgentBundleStamp: ManagedLaunchAgentBundleStamp {
    ManagedLaunchAgentBundleStamp(
      helperPath: helperPath,
      deviceIdentifier: deviceIdentifier,
      inode: inode,
      fileSize: fileSize,
      modificationTimeIntervalSince1970: modificationTimeIntervalSince1970,
      launchAgentPlistPath: launchAgentPlistPath,
      launchAgentPlistDeviceIdentifier: launchAgentPlistDeviceIdentifier,
      launchAgentPlistInode: launchAgentPlistInode,
      launchAgentPlistFileSize: launchAgentPlistFileSize,
      launchAgentPlistModificationTimeIntervalSince1970:
        launchAgentPlistModificationTimeIntervalSince1970
    )
  }
}

actor EndpointProbeRecorder {
  private var endpoints: [String] = []

  func record(_ endpoint: String) {
    endpoints.append(endpoint)
  }

  func values() -> [String] {
    endpoints
  }
}

func writeManagedLaunchAgentBundleStampFixture(
  _ stamp: ManagedLaunchAgentBundleStampFixture,
  environment: HarnessMonitorEnvironment
) throws {
  let url = HarnessMonitorPaths.daemonRoot(using: environment)
    .appendingPathComponent("managed-launch-agent-bundle-stamp.json")
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let data = try encoder.encode(stamp)
  try data.write(to: url)
}
