import Foundation
import HarnessMonitorKit

/// The board filter as it survives leaving the board and coming back.
enum TaskBoardFilterPreferences {
  static let storageKey = "harness.task-board.filters.v1"
  static let emptyRawValue = ""

  /// Decoding runs on every view body that reads the stored raw value, so a
  /// repeat of the same string answers from the memo instead of the decoder.
  @MainActor private static var memoizedRawValue: String?
  @MainActor private static var memoizedState = TaskBoardFilterState()

  @MainActor
  static func state(from rawValue: String) -> TaskBoardFilterState {
    if let memoizedRawValue, memoizedRawValue == rawValue {
      return memoizedState
    }
    let decoded = decode(rawValue)
    memoizedRawValue = rawValue
    memoizedState = decoded
    return decoded
  }

  static func rawValue(for state: TaskBoardFilterState) -> String {
    guard !state.isEmpty else {
      return emptyRawValue
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard
      let data = try? encoder.encode(Storage(state: state)),
      let rawValue = String(data: data, encoding: .utf8)
    else {
      return emptyRawValue
    }
    return rawValue
  }

  @MainActor
  static func load(from userDefaults: UserDefaults = .standard) -> TaskBoardFilterState {
    state(from: userDefaults.string(forKey: storageKey) ?? emptyRawValue)
  }

  static func save(_ state: TaskBoardFilterState, to userDefaults: UserDefaults = .standard) {
    let rawValue = rawValue(for: state)
    if rawValue.isEmpty {
      userDefaults.removeObject(forKey: storageKey)
    } else {
      userDefaults.set(rawValue, forKey: storageKey)
    }
  }

  private static func decode(_ rawValue: String) -> TaskBoardFilterState {
    guard
      let data = rawValue.data(using: .utf8),
      let storage = try? JSONDecoder().decode(Storage.self, from: data)
    else {
      return .init()
    }
    return storage.state
  }

  /// Each facet decodes on its own, so a stored filter written before a facet
  /// existed still restores every facet that did.
  private struct Storage: Codable {
    var projects: [String] = []
    var priorities: [String] = []
    var tags: [String] = []
    var sources: [String] = []

    init(state: TaskBoardFilterState) {
      projects = state.projects.sorted()
      priorities = state.priorities.map(\.rawValue).sorted()
      tags = state.tags.sorted()
      sources = state.sources.map(\.rawValue).sorted()
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      projects = try container.decodeIfPresent([String].self, forKey: .projects) ?? []
      priorities = try container.decodeIfPresent([String].self, forKey: .priorities) ?? []
      tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
      sources = try container.decodeIfPresent([String].self, forKey: .sources) ?? []
    }

    var state: TaskBoardFilterState {
      TaskBoardFilterState(
        projects: Set(projects),
        priorities: Set(priorities.compactMap(TaskBoardPriority.init(rawValue:))),
        tags: Set(tags.map(TaskBoardFilterState.tagKey)),
        sources: Set(sources.compactMap(TaskBoardFilterSource.init(rawValue:)))
      )
    }
  }
}
