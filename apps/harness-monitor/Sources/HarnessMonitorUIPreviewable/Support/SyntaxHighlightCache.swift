import Foundation
import HarnessMonitorKit
import os

/// Shared cached lexed representation for syntax-highlighted source.
/// The cache is synchronous so both SwiftUI surfaces and the Reviews
/// AppKit draw path can reuse the same lexed spans.
final class SyntaxHighlightCache: @unchecked Sendable {
  struct Key: Hashable, Sendable {
    let language: HarnessCodeLanguage
    let source: String

    private let fingerprint: Int

    init(language: HarnessCodeLanguage, source: String) {
      self.language = language
      self.source = source
      var hasher = Hasher()
      hasher.combine(language)
      hasher.combine(source)
      fingerprint = hasher.finalize()
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(language)
      hasher.combine(fingerprint)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.language == rhs.language && lhs.fingerprint == rhs.fingerprint && lhs.source == rhs.source
    }

    var perfLabel: String {
      "\(language.rawValue):\(fingerprint)"
    }
  }

  private struct Entry {
    var highlights: HarnessCodeHighlights
    var lastAccess: UInt64
  }

  private struct State {
    var entries: [Key: Entry] = [:]
    var accessClock: UInt64 = 0
  }

  static let shared = SyntaxHighlightCache()
  static let defaultMaxEntries = 256

  private let maxEntries: Int
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(maxEntries: Int = SyntaxHighlightCache.defaultMaxEntries) {
    self.maxEntries = maxEntries
  }

  func highlights(
    _ source: String,
    language: HarnessCodeLanguage,
    producer: () -> HarnessCodeHighlights
  ) -> HarnessCodeHighlights {
    let key = Key(language: language, source: source)
    if let cached = cached(for: key) {
      return cached
    }

    let interval = ReviewFilesPerf.beginTokenize(path: key.perfLabel)
    let highlights = producer()
    ReviewFilesPerf.end(interval)

    state.withLock { state in
      state.entries[key] = Entry(highlights: highlights, lastAccess: nextAccess(state: &state))
      evictIfNeeded(state: &state)
    }
    return highlights
  }

  func cached(
    source: String,
    language: HarnessCodeLanguage
  ) -> HarnessCodeHighlights? {
    cached(for: Key(language: language, source: source))
  }

  func clear() {
    state.withLock {
      $0.entries.removeAll()
      $0.accessClock = 0
    }
  }

  func count() -> Int {
    state.withLock { $0.entries.count }
  }

  private func cached(for key: Key) -> HarnessCodeHighlights? {
    state.withLock { state in
      guard var cached = state.entries[key] else { return nil }
      cached.lastAccess = nextAccess(state: &state)
      state.entries[key] = cached
      return cached.highlights
    }
  }

  private func nextAccess(state: inout State) -> UInt64 {
    state.accessClock &+= 1
    return state.accessClock
  }

  private func evictIfNeeded(state: inout State) {
    while state.entries.count > maxEntries,
      let oldest = state.entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
    {
      state.entries.removeValue(forKey: oldest)
    }
  }
}
