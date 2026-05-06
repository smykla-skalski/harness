import Foundation

/// Runtime-lane classification mirroring daemon discovery adoption rules.
/// Two Monitor instances may adopt or refresh the same managed daemon only
/// when they resolve to the same lane, or when both are unscoped.
public enum HarnessMonitorLaneFamily: Equatable {
  case lane(String)
  case unscoped

  public static func from(lane: String?) -> Self {
    guard let lane = lane?.trimmingCharacters(in: .whitespacesAndNewlines),
      !lane.isEmpty
    else {
      return Self.unscoped
    }
    return Self.lane(lane)
  }

  public static func from(rootPath: String) -> Self {
    let components = NSString(string: rootPath).standardizingPath
      .split(separator: "/")
      .map(String.init)
    let laneDirectoryIndex = components.firstIndex(
      of: HarnessMonitorRuntimeLane.dataHomeLanesDirectoryName
    )
    guard let laneDirectoryIndex,
      components.indices.contains(laneDirectoryIndex + 1)
    else {
      return Self.unscoped
    }
    return from(lane: components[laneDirectoryIndex + 1])
  }

  public static func compatible(
    _ own: Self,
    _ sibling: Self
  ) -> Bool {
    own == sibling
  }
}

extension HarnessMonitorPaths {
  public static func ownLaneFamily(
    using environment: HarnessMonitorEnvironment = .current
  ) -> HarnessMonitorLaneFamily {
    HarnessMonitorLaneFamily.from(
      lane: resolvedRuntimeLane(using: environment)
    )
  }

  public static func laneFamily(forRoot rootURL: URL) -> HarnessMonitorLaneFamily {
    HarnessMonitorLaneFamily.from(rootPath: rootURL.path)
  }
}
