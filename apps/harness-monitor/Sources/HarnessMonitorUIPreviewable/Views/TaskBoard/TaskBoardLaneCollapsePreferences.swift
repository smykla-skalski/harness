import Foundation
import HarnessMonitorKit

enum TaskBoardLaneCollapsePreferences {
  static let storageKey = "harness.task-board.lane-collapse-overrides.v1"
  static let emptyRawValue = "{}"

  static func overrides(from rawValue: String) -> [TaskBoardInboxLane: Bool] {
    guard let data = rawValue.data(using: .utf8) else {
      return [:]
    }
    let decoded = (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:]
    var overrides: [TaskBoardInboxLane: Bool] = decoded.reduce(into: [:]) { result, entry in
      guard entry.key != "umbrella" else {
        return
      }
      guard let lane = TaskBoardInboxLane(rawValue: entry.key) else {
        return
      }
      result[lane] = entry.value
    }
    if overrides[.backlog] == nil, let legacyOverride = decoded["umbrella"] {
      overrides[.backlog] = legacyOverride
    }
    return overrides
  }

  static func rawValue(for overrides: [TaskBoardInboxLane: Bool]) -> String {
    guard !overrides.isEmpty else {
      return emptyRawValue
    }

    let encodable = Dictionary(
      uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard
      let data = try? encoder.encode(encodable),
      let rawValue = String(data: data, encoding: .utf8)
    else {
      return emptyRawValue
    }
    return rawValue
  }

  static func load(from userDefaults: UserDefaults = .standard) -> [TaskBoardInboxLane: Bool] {
    overrides(from: userDefaults.string(forKey: storageKey) ?? emptyRawValue)
  }

  static func save(
    _ overrides: [TaskBoardInboxLane: Bool],
    to userDefaults: UserDefaults = .standard
  ) {
    userDefaults.set(rawValue(for: overrides), forKey: storageKey)
  }

  static func isCollapsed(
    lane: TaskBoardInboxLane,
    contentCount: Int,
    rawValue: String
  ) -> Bool {
    isCollapsed(lane: lane, contentCount: contentCount, overrides: overrides(from: rawValue))
  }

  static func isCollapsed(
    lane: TaskBoardInboxLane,
    contentCount: Int,
    overrides: [TaskBoardInboxLane: Bool]
  ) -> Bool {
    if let override = overrides[lane] {
      return override
    }
    return contentCount == 0
  }

  static func toggledRawValue(
    lane: TaskBoardInboxLane,
    contentCount: Int,
    rawValue: String
  ) -> String {
    var overrides = overrides(from: rawValue)
    overrides[lane] = !isCollapsed(
      lane: lane,
      contentCount: contentCount,
      overrides: overrides
    )
    return Self.rawValue(for: overrides)
  }
}
