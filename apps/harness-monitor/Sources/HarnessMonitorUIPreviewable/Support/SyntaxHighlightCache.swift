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
  }

  private struct State {
    var entries: [Key: HarnessCodeHighlights] = [:]
    var insertionOrder: [Key] = []
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

    let interval = ReviewFilesPerf.beginTokenize(path: "\(language.rawValue):\(source.hashValue)")
    let highlights = producer()
    ReviewFilesPerf.end(interval)

    state.withLock { state in
      if state.entries[key] == nil {
        state.insertionOrder.append(key)
      } else {
        promoteRecentlyUsed(key: key, state: &state)
      }
      state.entries[key] = highlights
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
      $0.insertionOrder.removeAll()
    }
  }

  func count() -> Int {
    state.withLock { $0.entries.count }
  }

  private func cached(for key: Key) -> HarnessCodeHighlights? {
    state.withLock { state in
      guard let cached = state.entries[key] else { return nil }
      promoteRecentlyUsed(key: key, state: &state)
      return cached
    }
  }

  private func promoteRecentlyUsed(key: Key, state: inout State) {
    state.insertionOrder.removeAll { $0 == key }
    state.insertionOrder.append(key)
  }

  private func evictIfNeeded(state: inout State) {
    while state.entries.count > maxEntries, let oldest = state.insertionOrder.first {
      state.insertionOrder.removeFirst()
      state.entries.removeValue(forKey: oldest)
    }
  }
}
