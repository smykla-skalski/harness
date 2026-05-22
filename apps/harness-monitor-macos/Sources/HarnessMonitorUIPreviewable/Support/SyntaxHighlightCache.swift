import Foundation

/// Shared off-main tokenization cache for the Dependencies > Files
/// diff renderer. Keyed by `(language, sha256(source))` so the same
/// patch body tokenizes once even when several file cards render
/// concurrently. Kept separate from `HarnessMarkdownRenderCache` to
/// preserve that cache's single-thread contract.
actor SyntaxHighlightCache {
  static let shared = SyntaxHighlightCache()

  struct Key: Hashable, Sendable {
    let language: HarnessCodeLanguage
    let sourceHash: String
  }

  public static let defaultMaxEntries: Int = 256

  private let maxEntries: Int
  private var entries: [Key: [HarnessCodeToken]] = [:]
  private var insertionOrder: [Key] = []

  init(maxEntries: Int = SyntaxHighlightCache.defaultMaxEntries) {
    self.maxEntries = maxEntries
  }

  /// Return cached tokens when present, otherwise tokenize off-actor
  /// via `Task.detached` and store. Concurrent calls for distinct
  /// keys actually run in parallel because the actor releases its
  /// executor while awaiting the detached task.
  func tokenize(
    _ source: String,
    language: HarnessCodeLanguage
  ) async -> [HarnessCodeToken] {
    let key = Key(language: language, sourceHash: Self.hash(for: source))
    if let cached = entries[key] {
      promoteRecentlyUsed(key: key)
      return cached
    }
    let tokens = await Task.detached(priority: .utility) {
      HarnessCodeHighlighter.highlight(source, language: language)
    }.value
    insert(key: key, tokens: tokens)
    return tokens
  }

  func cached(
    language: HarnessCodeLanguage,
    source: String
  ) -> [HarnessCodeToken]? {
    let key = Key(language: language, sourceHash: Self.hash(for: source))
    guard let cached = entries[key] else { return nil }
    promoteRecentlyUsed(key: key)
    return cached
  }

  func clear() {
    entries.removeAll()
    insertionOrder.removeAll()
  }

  func count() -> Int { entries.count }

  // MARK: - Internals

  private func insert(key: Key, tokens: [HarnessCodeToken]) {
    if entries[key] == nil {
      insertionOrder.append(key)
    } else {
      promoteRecentlyUsed(key: key)
    }
    entries[key] = tokens
    evictUntilUnderCap()
  }

  private func promoteRecentlyUsed(key: Key) {
    insertionOrder.removeAll { $0 == key }
    insertionOrder.append(key)
  }

  private func evictUntilUnderCap() {
    while entries.count > maxEntries, let oldest = insertionOrder.first {
      insertionOrder.removeFirst()
      entries.removeValue(forKey: oldest)
    }
  }

  static func hash(for source: String) -> String {
    var hasher = Hasher()
    hasher.combine(source)
    return String(hasher.finalize(), radix: 16, uppercase: false)
  }
}
