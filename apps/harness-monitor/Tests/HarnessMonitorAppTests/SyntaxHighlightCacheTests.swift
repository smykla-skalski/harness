import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

struct SyntaxHighlightCacheTests {
  @Test("tokenize caches results so a repeat call for the same source returns the same tokens")
  func cacheHitForSameSource() async {
    let cache = SyntaxHighlightCache()
    let source = "let x: Int = 42"
    let first = await cache.tokenize(source, language: .swift)
    let cached = await cache.cached(language: .swift, source: source)
    #expect(cached == first)
  }

  @Test("tokenize keeps separate entries per language even for identical source text")
  func cacheKeysIncludeLanguage() async {
    let cache = SyntaxHighlightCache()
    let source = "let x = 1"
    _ = await cache.tokenize(source, language: .swift)
    let rustCached = await cache.cached(language: .rust, source: source)
    let swiftCached = await cache.cached(language: .swift, source: source)
    #expect(rustCached == nil)
    #expect(swiftCached != nil)
  }

  @Test("concurrent tokenize calls from many tasks complete without crashing")
  func concurrentTokenizeSurvives() async {
    let cache = SyntaxHighlightCache()
    let inputs = (0..<16).map { "let value_\($0): Int = \($0)" }
    await withTaskGroup(of: Int.self) { group in
      for source in inputs {
        group.addTask {
          let tokens = await cache.tokenize(source, language: .swift)
          return tokens.count
        }
      }
      var produced = 0
      for await count in group where count > 0 { produced += 1 }
      #expect(produced == inputs.count)
    }
  }

  @Test("LRU evicts the least-recently-used entry when the cap is exceeded")
  func lruEvictsOldest() async {
    let cache = SyntaxHighlightCache(maxEntries: 3)
    _ = await cache.tokenize("source-1", language: .swift)
    _ = await cache.tokenize("source-2", language: .swift)
    _ = await cache.tokenize("source-3", language: .swift)
    // Touch source-1 so it's most recently used; source-2 is the oldest.
    _ = await cache.cached(language: .swift, source: "source-1")
    _ = await cache.tokenize("source-4", language: .swift)
    #expect(await cache.cached(language: .swift, source: "source-2") == nil)
    #expect(await cache.cached(language: .swift, source: "source-1") != nil)
    #expect(await cache.cached(language: .swift, source: "source-3") != nil)
    #expect(await cache.cached(language: .swift, source: "source-4") != nil)
    #expect(await cache.count() == 3)
  }

  @Test("clear drops every cached tokenization")
  func clearWipes() async {
    let cache = SyntaxHighlightCache()
    _ = await cache.tokenize("let x = 1", language: .swift)
    await cache.clear()
    #expect(await cache.count() == 0)
    #expect(await cache.cached(language: .swift, source: "let x = 1") == nil)
  }
}
