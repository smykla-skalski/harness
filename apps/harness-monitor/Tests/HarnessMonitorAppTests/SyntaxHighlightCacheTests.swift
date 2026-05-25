import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

struct SyntaxHighlightCacheTests {
  @Test("highlights caches results so a repeat call for the same source returns the same spans")
  func cacheHitForSameSource() {
    let cache = SyntaxHighlightCache()
    let source = "let x: Int = 42"
    let first = cache.highlights(source, language: .swift) {
      HarnessCodeHighlighter.highlightsUncached(source, language: .swift)
    }
    let cached = cache.cached(source: source, language: .swift)
    #expect(cached == first)
  }

  @Test("highlights keeps separate entries per language even for identical source text")
  func cacheKeysIncludeLanguage() {
    let cache = SyntaxHighlightCache()
    let source = "let x = 1"
    _ = cache.highlights(source, language: .swift) {
      HarnessCodeHighlighter.highlightsUncached(source, language: .swift)
    }
    let rustCached = cache.cached(source: source, language: .rust)
    let swiftCached = cache.cached(source: source, language: .swift)
    #expect(rustCached == nil)
    #expect(swiftCached != nil)
  }

  @Test("concurrent highlight calls from many tasks complete without crashing")
  func concurrentTokenizeSurvives() async {
    let cache = SyntaxHighlightCache()
    let inputs = (0..<16).map { "let value_\($0): Int = \($0)" }
    await withTaskGroup(of: Int.self) { group in
      for source in inputs {
        group.addTask {
          let highlights = cache.highlights(source, language: .swift) {
            HarnessCodeHighlighter.highlightsUncached(source, language: .swift)
          }
          return highlights.spans.count
        }
      }
      var produced = 0
      for await count in group where count > 0 { produced += 1 }
      #expect(produced == inputs.count)
    }
  }

  @Test("LRU evicts the least-recently-used entry when the cap is exceeded")
  func lruEvictsOldest() {
    let cache = SyntaxHighlightCache(maxEntries: 3)
    _ = cache.highlights("source-1", language: .swift) {
      HarnessCodeHighlighter.highlightsUncached("source-1", language: .swift)
    }
    _ = cache.highlights("source-2", language: .swift) {
      HarnessCodeHighlighter.highlightsUncached("source-2", language: .swift)
    }
    _ = cache.highlights("source-3", language: .swift) {
      HarnessCodeHighlighter.highlightsUncached("source-3", language: .swift)
    }
    // Touch source-1 so it's most recently used; source-2 is the oldest.
    _ = cache.cached(source: "source-1", language: .swift)
    _ = cache.highlights("source-4", language: .swift) {
      HarnessCodeHighlighter.highlightsUncached("source-4", language: .swift)
    }
    #expect(cache.cached(source: "source-2", language: .swift) == nil)
    #expect(cache.cached(source: "source-1", language: .swift) != nil)
    #expect(cache.cached(source: "source-3", language: .swift) != nil)
    #expect(cache.cached(source: "source-4", language: .swift) != nil)
    #expect(cache.count() == 3)
  }

  @Test("clear drops every cached highlight")
  func clearWipes() {
    let cache = SyntaxHighlightCache()
    _ = cache.highlights("let x = 1", language: .swift) {
      HarnessCodeHighlighter.highlightsUncached("let x = 1", language: .swift)
    }
    cache.clear()
    #expect(cache.count() == 0)
    #expect(cache.cached(source: "let x = 1", language: .swift) == nil)
  }
}
