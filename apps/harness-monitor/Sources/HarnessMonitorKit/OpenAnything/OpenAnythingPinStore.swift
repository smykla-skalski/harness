import Foundation
import Observation

/// Persisted list of pinned Open Anything record ids. Pinned records always
/// surface at the top of the palette's empty-query lane in the order the user
/// pinned them.
///
/// Persisted to UserDefaults under `OpenAnythingPinStore.storageKey`.
/// Capped at 10 entries so the empty-query lane stays scannable.
@MainActor
@Observable
public final class OpenAnythingPinStore {
  public static let storageKey = "harness.openAnything.pinned"
  public static let capacity = 10

  public private(set) var recordIDs: [String]

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let key: String

  public init(
    defaults: UserDefaults = .standard,
    key: String = OpenAnythingPinStore.storageKey
  ) {
    self.defaults = defaults
    self.key = key
    recordIDs = Self.load(from: defaults, key: key)
  }

  /// Whether `recordID` is currently pinned.
  public func isPinned(_ recordID: String) -> Bool {
    recordIDs.contains(recordID)
  }

  /// Pin a record at the end of the list. No-op if already pinned or at capacity.
  /// Returns whether the call changed state.
  @discardableResult
  public func pin(_ recordID: String) -> Bool {
    guard !recordIDs.contains(recordID), recordIDs.count < Self.capacity else {
      return false
    }
    recordIDs.append(recordID)
    persist()
    return true
  }

  /// Unpin a record. Returns whether the call changed state.
  @discardableResult
  public func unpin(_ recordID: String) -> Bool {
    guard let index = recordIDs.firstIndex(of: recordID) else { return false }
    recordIDs.remove(at: index)
    persist()
    return true
  }

  /// Move a pinned record to a new position. No-op if not pinned or position
  /// out of range. Returns whether the call changed state.
  @discardableResult
  public func move(_ recordID: String, to newIndex: Int) -> Bool {
    guard let currentIndex = recordIDs.firstIndex(of: recordID) else { return false }
    let clamped = max(0, min(newIndex, recordIDs.count - 1))
    guard clamped != currentIndex else { return false }
    recordIDs.remove(at: currentIndex)
    recordIDs.insert(recordID, at: clamped)
    persist()
    return true
  }

  /// Drop every pin. Used by Settings "Clear pins" and tests.
  public func clear() {
    guard !recordIDs.isEmpty else { return }
    recordIDs = []
    persist()
  }

  private func persist() {
    do {
      let data = try JSONEncoder().encode(recordIDs)
      defaults.set(data, forKey: key)
    } catch {
      // Persistence failure is non-fatal; in-memory state still works.
    }
  }

  private static func load(from defaults: UserDefaults, key: String) -> [String] {
    guard let data = defaults.data(forKey: key) else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
  }
}
