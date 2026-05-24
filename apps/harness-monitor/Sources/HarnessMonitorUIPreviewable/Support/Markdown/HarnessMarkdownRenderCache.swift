import Foundation

actor HarnessMarkdownRenderCache {
  static let shared = HarnessMarkdownRenderCache(capacity: 24)

  private let capacity: Int
  private var storage: [HarnessMarkdownRenderKey: HarnessMarkdownDocument] = [:]
  private var recency: [HarnessMarkdownRenderKey] = []

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  func document(for key: HarnessMarkdownRenderKey) -> HarnessMarkdownDocument? {
    guard let document = storage[key] else { return nil }
    touch(key)
    return document
  }

  func store(_ document: HarnessMarkdownDocument, for key: HarnessMarkdownRenderKey) {
    storage[key] = document
    touch(key)
    while recency.count > capacity, let evicted = recency.first {
      recency.removeFirst()
      storage.removeValue(forKey: evicted)
    }
  }

  private func touch(_ key: HarnessMarkdownRenderKey) {
    recency.removeAll { $0 == key }
    recency.append(key)
  }
}

struct HarnessMarkdownRenderKey: Hashable, Sendable {
  let sourceHash: Int
  let sourceLength: Int
  let rendering: HarnessMonitorMarkdownTextRendering
  let lineLimit: Int?

  init(markdown: String, rendering: HarnessMonitorMarkdownTextRendering, lineLimit: Int?) {
    sourceHash = markdown.hashValue
    sourceLength = markdown.count
    self.rendering = rendering
    self.lineLimit = lineLimit
  }
}
