import HarnessMonitorKit

@MainActor
final class DashboardReviewFileDiffDocumentCache {
  private struct Key: Hashable {
    let path: String
    let language: HarnessReviewFileLanguage
    let patch: String
    let truncated: Bool
    let headRefOid: String
  }

  private var documents: [Key: DashboardReviewFileDiffDocument] = [:]
  private var keys: [Key] = []
  private let limit: Int

  init(limit: Int = 12) {
    self.limit = limit
  }

  func document(
    patch: ReviewFilePatch,
    language: HarnessReviewFileLanguage
  ) -> DashboardReviewFileDiffDocument {
    let key = Key(
      path: patch.path,
      language: language,
      patch: patch.patch,
      truncated: patch.truncated,
      headRefOid: patch.headRefOid
    )
    if let document = documents[key] {
      return document
    }
    let document = DashboardReviewFileDiffDocument(patch: patch, language: language)
    documents[key] = document
    keys.append(key)
    evictIfNeeded()
    return document
  }

  private func evictIfNeeded() {
    while keys.count > limit, let key = keys.first {
      keys.removeFirst()
      documents.removeValue(forKey: key)
    }
  }
}
