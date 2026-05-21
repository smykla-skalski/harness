import Foundation

@testable import HarnessMonitorKit

func expectedDefaultAppGroupRoot(homeDirectory: URL) -> URL {
  expectedAppGroupRoot(
    identifier: HarnessMonitorAppGroup.identifier,
    homeDirectory: homeDirectory
  )
}

func expectedAppGroupRoot(identifier: String, homeDirectory: URL) -> URL {
  homeDirectory
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Group Containers", isDirectory: true)
    .appendingPathComponent(identifier, isDirectory: true)
}

func expectedRuntimeLaneRoot(homeDirectory: URL, lane: String) -> URL {
  expectedDefaultAppGroupRoot(homeDirectory: homeDirectory)
    .appendingPathComponent("runtime-lanes", isDirectory: true)
    .appendingPathComponent(lane, isDirectory: true)
}

func expectedHarnessRoot(in dataHomeRoot: URL) -> URL {
  dataHomeRoot.appendingPathComponent("harness", isDirectory: true)
}

func expectedDaemonRoot(
  in dataHomeRoot: URL,
  ownership: DaemonOwnership = .managed
) -> URL {
  expectedHarnessRoot(in: dataHomeRoot)
    .appendingPathComponent("daemon", isDirectory: true)
    .appendingPathComponent(ownership.rawValue, isDirectory: true)
}

func expectedManifestURL(
  in dataHomeRoot: URL,
  ownership: DaemonOwnership = .managed
) -> URL {
  expectedDaemonRoot(in: dataHomeRoot, ownership: ownership)
    .appendingPathComponent("manifest.json")
}

func expectedAuthTokenURL(
  in dataHomeRoot: URL,
  ownership: DaemonOwnership = .managed
) -> URL {
  expectedDaemonRoot(in: dataHomeRoot, ownership: ownership)
    .appendingPathComponent("auth-token")
}
