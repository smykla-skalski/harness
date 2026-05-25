import Foundation
import HarnessMonitorKit
import Observation
import SwiftUI

/// `@Observable` wrapper around `DashboardReviewsPreferences` that
/// publishes each settings field individually so views invalidating on
/// only one preference (e.g. `filesEnabled`) don't repaint when an
/// unrelated field (e.g. `filesGeneratedPatterns`) changes.
@Observable
@MainActor
final class ReviewsPreferencesStore {
  private(set) var snapshot: DashboardReviewsPreferences
  var compiledGeneratedPatternMatcher: ReviewFilesGeneratedPathMatcher

  @ObservationIgnored private let storage: any ReviewsPreferencesStorage
  @ObservationIgnored private var debouncedWriteTask: Task<Void, Never>?
  @ObservationIgnored private var regexCompileTask: Task<Void, Never>?
  @ObservationIgnored private var lastCompiledPatterns: [String] = []

  static let defaultDebounceNanoseconds: UInt64 = 250_000_000

  init(storage: any ReviewsPreferencesStorage) {
    self.storage = storage
    let initial =
      DashboardReviewsPreferences.decode(from: storage.load() ?? "")
    self.snapshot = initial
    self.compiledGeneratedPatternMatcher = Self.makeMatcher(
      from: initial.filesGeneratedPatterns
    )
    self.lastCompiledPatterns = initial.filesGeneratedPatterns
  }

  convenience init() {
    self.init(storage: UserDefaultsReviewsPreferencesStorage())
  }

  // MARK: - Public API

  func update(_ mutate: (inout DashboardReviewsPreferences) -> Void) {
    var copy = snapshot
    mutate(&copy)
    apply(copy)
  }

  func replace(_ next: DashboardReviewsPreferences) {
    apply(next)
  }

  /// Force-flush the debounced UserDefaults write. Used by tests and the
  /// `applicationWillTerminate` hook so a crash inside the debounce
  /// window can't lose the user's last preference change.
  func flushPendingWrites() async {
    if let task = debouncedWriteTask {
      await task.value
    }
  }

  // MARK: - Internals

  private func apply(_ next: DashboardReviewsPreferences) {
    guard next != snapshot else { return }
    let prevPatterns = snapshot.filesGeneratedPatterns
    snapshot = next
    if next.filesGeneratedPatterns != prevPatterns {
      scheduleRegexCompile(patterns: next.filesGeneratedPatterns)
    }
    scheduleDebouncedWrite()
  }

  private func scheduleDebouncedWrite() {
    debouncedWriteTask?.cancel()
    let payload = snapshot.encodedString
    let storage = self.storage
    debouncedWriteTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: Self.defaultDebounceNanoseconds)
      guard !Task.isCancelled else { return }
      storage.save(payload)
      self?.debouncedWriteTask = nil
    }
  }

  private func scheduleRegexCompile(patterns: [String]) {
    regexCompileTask?.cancel()
    regexCompileTask = Task.detached(priority: .utility) { [weak self] in
      let matcher = Self.makeMatcher(from: patterns)
      await self?.applyCompiledMatcher(patterns: patterns, matcher: matcher)
    }
  }

  private func applyCompiledMatcher(
    patterns: [String],
    matcher: ReviewFilesGeneratedPathMatcher
  ) {
    guard patterns == snapshot.filesGeneratedPatterns else { return }
    compiledGeneratedPatternMatcher = matcher
    lastCompiledPatterns = patterns
  }

  nonisolated static func makeMatcher(
    from patterns: [String]
  ) -> ReviewFilesGeneratedPathMatcher {
    ReviewFilesGeneratedPathMatcher.compiled(from: patterns)
  }
}

/// Abstracts the JSON-string persistence layer so tests can inject an
/// in-memory store. Defaults to `UserDefaults.standard`.
protocol ReviewsPreferencesStorage: Sendable {
  func load() -> String?
  func save(_ string: String)
}

struct UserDefaultsReviewsPreferencesStorage: ReviewsPreferencesStorage,
  @unchecked Sendable
{
  private let defaults: UserDefaults
  private let key: String

  init(
    defaults: UserDefaults = .standard,
    key: String = DashboardReviewsPreferences.storageKey
  ) {
    self.defaults = defaults
    self.key = key
  }

  func load() -> String? {
    defaults.string(forKey: key)
  }

  func save(_ string: String) {
    defaults.set(string, forKey: key)
  }
}

/// In-memory storage for tests + previews so they don't touch user
/// defaults.
final class InMemoryReviewsPreferencesStorage: ReviewsPreferencesStorage,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var value: String?

  init(initial: String? = nil) {
    self.value = initial
  }

  func load() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func save(_ string: String) {
    lock.lock()
    value = string
    lock.unlock()
  }
}

extension EnvironmentValues {
  @Entry var reviewsPreferences: ReviewsPreferencesStore = {
    MainActor.assumeIsolated {
      ReviewsPreferencesStore(storage: InMemoryReviewsPreferencesStorage())
    }
  }()
}
