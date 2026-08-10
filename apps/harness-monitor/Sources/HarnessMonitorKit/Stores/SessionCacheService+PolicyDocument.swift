import Foundation
import SwiftData

extension SessionCacheService {
  struct CachedPolicyDocumentSnapshot: Sendable {
    let canvasId: String
    let document: PolicyPipelineDocument
  }

  struct PolicyDocumentCacheWriteToken: Sendable {
    let canvasId: String
    let writeID: UUID
    let writtenData: Data
    let previousWriteID: UUID?
    let previousCachedAt: Date?
    let previousData: Data?
  }

  struct PolicyDocumentCacheWriteResult: Sendable {
    let didPersist: Bool
    let token: PolicyDocumentCacheWriteToken?
  }

  func cachePolicyDocument(
    canvasId: String,
    document: PolicyPipelineDocument
  ) async -> PolicyDocumentCacheWriteResult {
    await acquirePolicyDocumentTransaction(canvasId: canvasId)
    defer { releasePolicyDocumentTransaction(canvasId: canvasId) }
    let context = makeContext()
    let writeID = UUID()
    let previousWriteID = policyDocumentWriteIDsByCanvasID[canvasId]
    let token: PolicyDocumentCacheWriteToken
    do {
      let data = try Codecs.encoder.encode(document)
      var descriptor = FetchDescriptor<CachedPolicyDocument>(
        predicate: #Predicate { $0.canvasId == canvasId }
      )
      descriptor.fetchLimit = 1
      if let existing = try context.fetch(descriptor).first {
        let cachedAt = nextPolicyDocumentCacheDate(after: existing.cachedAt)
        token = PolicyDocumentCacheWriteToken(
          canvasId: canvasId,
          writeID: writeID,
          writtenData: data,
          previousWriteID: previousWriteID,
          previousCachedAt: existing.cachedAt,
          previousData: existing.documentData
        )
        existing.documentData = data
        existing.cachedAt = cachedAt
      } else {
        let cachedAt = Date.now
        token = PolicyDocumentCacheWriteToken(
          canvasId: canvasId,
          writeID: writeID,
          writtenData: data,
          previousWriteID: previousWriteID,
          previousCachedAt: nil,
          previousData: nil
        )
        context.insert(
          CachedPolicyDocument(
            canvasId: canvasId,
            cachedAt: cachedAt,
            documentData: data
          )
        )
      }
    } catch {
      HarnessMonitorLogger.store.warning(
        "cache policy document failed: \(error.localizedDescription, privacy: .public)"
      )
      return PolicyDocumentCacheWriteResult(didPersist: false, token: nil)
    }
    let didPersist = await persist(context, operation: "cache policy document")
    if didPersist {
      policyDocumentWriteIDsByCanvasID[canvasId] = writeID
    }
    return PolicyDocumentCacheWriteResult(
      didPersist: didPersist,
      token: didPersist ? token : nil
    )
  }

  private func nextPolicyDocumentCacheDate(after cachedAt: Date) -> Date {
    let now = Date.now
    guard now <= cachedAt else { return now }
    return cachedAt.addingTimeInterval(0.001)
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

  @discardableResult
  func rollbackPolicyDocumentCacheWrite(
    _ token: PolicyDocumentCacheWriteToken
  ) async -> Bool {
    await acquirePolicyDocumentTransaction(canvasId: token.canvasId)
    defer { releasePolicyDocumentTransaction(canvasId: token.canvasId) }
    guard policyDocumentWriteIDsByCanvasID[token.canvasId] == token.writeID else {
      return false
    }
    let context = makeContext()
    let canvasId = token.canvasId
    do {
      var descriptor = FetchDescriptor<CachedPolicyDocument>(
        predicate: #Predicate { $0.canvasId == canvasId }
      )
      descriptor.fetchLimit = 1
      guard let cached = try context.fetch(descriptor).first,
        cached.documentData == token.writtenData
      else { return false }
      if let previousCachedAt = token.previousCachedAt,
        let previousData = token.previousData
      {
        cached.cachedAt = previousCachedAt
        cached.documentData = previousData
      } else {
        context.delete(cached)
      }
    } catch {
      HarnessMonitorLogger.store.warning(
        "rollback stale policy document failed: \(error.localizedDescription, privacy: .public)"
      )
      return false
    }
    if await persist(context, operation: "rollback stale policy document") {
      policyDocumentWriteIDsByCanvasID[canvasId] = token.previousWriteID
      return true
    }
    return false
  }

  private func acquirePolicyDocumentTransaction(canvasId: String) async {
    if activePolicyDocumentTransactions.insert(canvasId).inserted {
      return
    }
    await withCheckedContinuation { continuation in
      policyDocumentTransactionWaiters[canvasId, default: []].append(continuation)
    }
  }

  private func releasePolicyDocumentTransaction(canvasId: String) {
    guard var waiters = policyDocumentTransactionWaiters[canvasId], !waiters.isEmpty else {
      activePolicyDocumentTransactions.remove(canvasId)
      policyDocumentTransactionWaiters[canvasId] = nil
      return
    }
    let next = waiters.removeFirst()
    policyDocumentTransactionWaiters[canvasId] = waiters.isEmpty ? nil : waiters
    next.resume()
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
