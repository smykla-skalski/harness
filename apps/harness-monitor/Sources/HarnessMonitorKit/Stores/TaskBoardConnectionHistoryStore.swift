import Foundation

@MainActor
final class TaskBoardConnectionHistoryStore {
  private struct State: Codable {
    var lastConnectedDatabaseInstanceID: String?
    var repositoryOverrideSlugs: [String: [String]] = [:]
  }

  private static let defaultKey = "harness.task-board.connection-history.v1"

  private let defaults: UserDefaults?
  private let key: String
  private var state: State

  init(defaults: UserDefaults? = .standard, key: String = defaultKey) {
    self.defaults = defaults
    self.key = key
    if let data = defaults?.data(forKey: key),
      let decoded = try? JSONDecoder().decode(State.self, from: data)
    {
      state = decoded
    } else {
      state = State()
    }
  }

  func noteConnectedDatabaseInstance(_ instanceID: String) -> String? {
    let previous = state.lastConnectedDatabaseInstanceID
    state.lastConnectedDatabaseInstanceID = instanceID
    persist()
    return previous == instanceID ? nil : previous
  }

  func recordRepositoryOverrideSlugs(_ slugs: Set<String>, instanceID: String) {
    guard !slugs.isEmpty else { return }
    let existing = Set(state.repositoryOverrideSlugs[instanceID] ?? [])
    state.repositoryOverrideSlugs[instanceID] = existing.union(slugs).sorted()
    persist()
  }

  func repositoryOverrideSlugs(instanceID: String) -> Set<String> {
    Set(state.repositoryOverrideSlugs[instanceID] ?? [])
  }

  private func persist() {
    guard let defaults, let encoded = try? JSONEncoder().encode(state) else { return }
    defaults.set(encoded, forKey: key)
  }
}
