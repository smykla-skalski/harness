import Foundation
import SwiftData

extension SessionCacheService {
  struct CachedPolicyDocumentSnapshot: Sendable {
    let canvasId: String
    let document: PolicyPipelineDocument
  }

  func cachePolicyDocument(
    canvasId: String,
    document: PolicyPipelineDocument
  ) async -> WriteResult {
    let context = makeContext()
    do {
      let data = try Codecs.encoder.encode(document)
      var descriptor = FetchDescriptor<CachedPolicyDocument>(
        predicate: #Predicate { $0.canvasId == canvasId }
      )
      descriptor.fetchLimit = 1
      if let existing = try context.fetch(descriptor).first {
        existing.documentData = data
        existing.cachedAt = .now
      } else {
        context.insert(CachedPolicyDocument(canvasId: canvasId, documentData: data))
      }
    } catch {
      HarnessMonitorLogger.store.warning(
        "cache policy document failed: \(error.localizedDescription, privacy: .public)"
      )
      return WriteResult(didPersist: false, metadataUpdate: .none)
    }
    let didPersist = await persist(context, operation: "cache policy document")
    return WriteResult(didPersist: didPersist, metadataUpdate: .none)
  }

  func loadPolicyDocument(
    canvasId: String
  ) -> PolicyPipelineDocument? {
    let context = makeContext()
    var descriptor = FetchDescriptor<CachedPolicyDocument>(
      predicate: #Predicate { $0.canvasId == canvasId }
    )
    descriptor.fetchLimit = 1
    guard let cached = try? context.fetch(descriptor).first else {
      return nil
    }
    return try? cached.decodedDocument()
  }

  func loadMostRecentPolicyDocument() -> PolicyPipelineDocument? {
    loadMostRecentPolicyDocumentSnapshot()?.document
  }

  func loadMostRecentPolicyDocumentSnapshot() -> CachedPolicyDocumentSnapshot? {
    let context = makeContext()
    var descriptor = FetchDescriptor<CachedPolicyDocument>(
      sortBy: [SortDescriptor(\.cachedAt, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    guard let cached = try? context.fetch(descriptor).first else {
      return nil
    }
    guard let document = try? cached.decodedDocument() else {
      return nil
    }
    return CachedPolicyDocumentSnapshot(canvasId: cached.canvasId, document: document)
  }
}
