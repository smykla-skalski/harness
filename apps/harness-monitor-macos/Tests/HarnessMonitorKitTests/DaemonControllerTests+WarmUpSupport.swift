import Foundation

@testable import HarnessMonitorKit

struct ManagedLaunchAgentBundleStampFixture: Codable {
  let helperPath: String
  let deviceIdentifier: UInt64
  let inode: UInt64
  let fileSize: UInt64
  let modificationTimeIntervalSince1970: Double
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
