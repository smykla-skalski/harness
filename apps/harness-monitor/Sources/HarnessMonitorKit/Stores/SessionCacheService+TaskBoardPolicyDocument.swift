import Foundation
import SwiftData

extension SessionCacheService {
  func cacheTaskBoardPolicyDocument(
    canvasId: String,
    document: TaskBoardPolicyPipelineDocument
  ) async -> WriteResult {
    let context = makeContext()
    do {
      let data = try Codecs.encoder.encode(document)
      var descriptor = FetchDescriptor<CachedTaskBoardPolicyDocument>(
        predicate: #Predicate { $0.canvasId == canvasId }
      )
      descriptor.fetchLimit = 1
      if let existing = try context.fetch(descriptor).first {
        existing.documentData = data
        existing.cachedAt = .now
      } else {
        context.insert(CachedTaskBoardPolicyDocument(canvasId: canvasId, documentData: data))
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

  func loadTaskBoardPolicyDocument(
    canvasId: String
  ) -> TaskBoardPolicyPipelineDocument? {
    let context = makeContext()
    var descriptor = FetchDescriptor<CachedTaskBoardPolicyDocument>(
      predicate: #Predicate { $0.canvasId == canvasId }
    )
    descriptor.fetchLimit = 1
    guard let cached = try? context.fetch(descriptor).first else {
      return nil
    }
    return try? cached.decodedDocument()
  }

  func loadMostRecentTaskBoardPolicyDocument() -> TaskBoardPolicyPipelineDocument? {
    let context = makeContext()
    var descriptor = FetchDescriptor<CachedTaskBoardPolicyDocument>(
      sortBy: [SortDescriptor(\.cachedAt, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    guard let cached = try? context.fetch(descriptor).first else {
      return nil
    }
    return try? cached.decodedDocument()
  }
}
