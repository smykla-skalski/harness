import Foundation

public struct TaskBoardHostMachine: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let projectTypes: [String]
  public let agentModes: [TaskBoardAgentMode]
  public let lastSeen: String

  public init(
    id: String,
    label: String,
    projectTypes: [String] = [],
    agentModes: [TaskBoardAgentMode] = [],
    lastSeen: String
  ) {
    self.id = id
    self.label = label
    self.projectTypes = projectTypes
    self.agentModes = agentModes
    self.lastSeen = lastSeen
  }

  enum CodingKeys: String, CodingKey {
    case id
    case label
    case projectTypes
    case agentModes
    case lastSeen
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      label: try container.decode(String.self, forKey: .label),
      projectTypes: try container.decodeIfPresent([String].self, forKey: .projectTypes) ?? [],
      agentModes: try container.decodeIfPresent([TaskBoardAgentMode].self, forKey: .agentModes)
        ?? [],
      lastSeen: try container.decode(String.self, forKey: .lastSeen)
    )
  }
}

public struct TaskBoardHostSetProjectTypesRequest: Codable, Equatable, Sendable {
  public let projectTypes: [String]

  public init(projectTypes: [String] = []) {
    self.projectTypes = projectTypes
  }
}

extension TaskBoardHostMachine {
  /// Returns true when this host accepts the given board item's
  /// `targetProjectTypes`. Mirrors the Rust `Machine::accepts_any` rule:
  /// items with empty `targetProjectTypes` route to every host; otherwise
  /// at least one target must match a declared host `projectType`
  /// (case-insensitive, trimmed).
  public func acceptsAny(itemTargetProjectTypes: [String]) -> Bool {
    Self.acceptsAny(
      machineProjectTypes: projectTypes,
      itemTargetProjectTypes: itemTargetProjectTypes
    )
  }

  public static func acceptsAny(
    machineProjectTypes: [String],
    itemTargetProjectTypes: [String]
  ) -> Bool {
    if itemTargetProjectTypes.isEmpty {
      return true
    }
    let declared = machineProjectTypes
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
    if declared.isEmpty {
      return true
    }
    for target in itemTargetProjectTypes {
      let needle = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !needle.isEmpty else { continue }
      if declared.contains(needle) {
        return true
      }
    }
    return false
  }

  /// Filters `items` to those the host accepts based on each item's
  /// `targetProjectTypes`. Used by the dispatch picker to hide items that
  /// can't run on this host.
  public static func dispatchableItems(
    _ items: [TaskBoardItem],
    machineProjectTypes: [String]
  ) -> [TaskBoardItem] {
    items.filter { item in
      acceptsAny(
        machineProjectTypes: machineProjectTypes,
        itemTargetProjectTypes: item.targetProjectTypes
      )
    }
  }
}
