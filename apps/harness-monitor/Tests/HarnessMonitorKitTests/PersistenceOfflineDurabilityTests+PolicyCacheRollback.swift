import Testing

@testable import HarnessMonitorKit

@MainActor
extension PersistenceOfflineDurabilityTests {
  @Test("Stale policy rollback restores the exact previous cache entry")
  func stalePolicyRollbackRestoresExactPreviousCacheEntry() async throws {
    let client = RecordingHarnessClient()
    let cache = SessionCacheService(modelContainer: previewContainer)
    let original = client.samplePolicyPipeline(
      canvasId: "canvas-rollback",
      title: "Original",
      revision: 1
    )
    let stale = client.samplePolicyPipeline(
      canvasId: "canvas-rollback",
      title: "Stale",
      revision: 2
    )
    let originalWrite = await cache.cachePolicyDocument(
      canvasId: "canvas-rollback",
      document: original
    )
    #expect(originalWrite.didPersist)
    let loadedOriginal = try #require(
      await cache.loadPolicyDocument(canvasId: "canvas-rollback")
    )
    #expect(loadedOriginal.revision == original.revision)
    #expect(loadedOriginal.nodes.first?.title == "Original")
    let staleWrite = await cache.cachePolicyDocument(
      canvasId: "canvas-rollback",
      document: stale
    )
    #expect(staleWrite.didPersist)
    let loadedStale = try #require(
      await cache.loadPolicyDocument(canvasId: "canvas-rollback")
    )
    #expect(loadedStale.revision == stale.revision)
    #expect(loadedStale.nodes.first?.title == "Stale")

    let token = try #require(staleWrite.token)
    #expect(await cache.rollbackPolicyDocumentCacheWrite(token))

    let restored = try #require(
      await cache.loadPolicyDocument(canvasId: "canvas-rollback")
    )
    #expect(restored.revision == original.revision)
    #expect(restored.nodes.first?.title == "Original")
  }

  @Test("Stale policy rollback preserves a newer identical cache write")
  func stalePolicyRollbackPreservesNewerIdenticalCacheWrite() async throws {
    let client = RecordingHarnessClient()
    let cache = SessionCacheService(modelContainer: previewContainer)
    let document = client.samplePolicyPipeline(
      canvasId: "canvas-identical",
      title: "Identical",
      revision: 3
    )
    let staleWrite = await cache.cachePolicyDocument(
      canvasId: "canvas-identical",
      document: document
    )
    let newerWrite = await cache.cachePolicyDocument(
      canvasId: "canvas-identical",
      document: document
    )
    #expect(staleWrite.didPersist)
    #expect(newerWrite.didPersist)

    let token = try #require(staleWrite.token)
    #expect(!(await cache.rollbackPolicyDocumentCacheWrite(token)))

    let preserved = try #require(
      await cache.loadPolicyDocument(canvasId: "canvas-identical")
    )
    #expect(preserved.revision == document.revision)
    #expect(preserved.nodes.first?.title == "Identical")
  }

  @Test("Policy cache writes for one canvas persist in invocation order")
  func policyCacheWritesPersistInInvocationOrder() async throws {
    let client = RecordingHarnessClient()
    let gate = PolicyCacheFirstSaveGate()
    let cache = SessionCacheService(
      modelContainer: previewContainer,
      beforeSave: { await gate.waitIfFirstSave() }
    )
    let firstDocument = client.samplePolicyPipeline(
      canvasId: "canvas-serialized",
      title: "First",
      revision: 1
    )
    let secondDocument = client.samplePolicyPipeline(
      canvasId: "canvas-serialized",
      title: "Second",
      revision: 2
    )
    let firstWrite = Task {
      await cache.cachePolicyDocument(
        canvasId: "canvas-serialized",
        document: firstDocument
      )
    }
    await gate.waitUntilFirstSaveIsBlocked()
    let secondWrite = Task {
      await cache.cachePolicyDocument(
        canvasId: "canvas-serialized",
        document: secondDocument
      )
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await gate.saveEntryCount == 1)

    await gate.releaseFirstSave()
    #expect(await firstWrite.value.didPersist)
    #expect(await secondWrite.value.didPersist)
    let cached = try #require(
      await cache.loadPolicyDocument(canvasId: "canvas-serialized")
    )
    #expect(cached.revision == secondDocument.revision)
    #expect(cached.nodes.first?.title == "Second")
  }

  @Test("Policy cache invalidation drains older writes")
  func policyCacheInvalidationDrainsOlderWrites() async throws {
    let client = RecordingHarnessClient()
    let gate = PolicyCacheFirstSaveGate()
    let cache = SessionCacheService(
      modelContainer: previewContainer,
      beforeSave: { await gate.waitIfFirstSave() }
    )
    let staleDocument = client.samplePolicyPipeline(
      canvasId: "canvas-stale",
      title: "Stale",
      revision: 1
    )
    let staleWrite = Task {
      await cache.cachePolicyDocument(
        canvasId: "canvas-stale",
        document: staleDocument,
        sourceGeneration: 0
      )
    }
    await gate.waitUntilFirstSaveIsBlocked()
    let invalidation = Task {
      await cache.clearPolicyDocuments(sourceGeneration: 1)
    }

    await gate.releaseFirstSave()
    #expect(await staleWrite.value.didPersist)
    #expect(await invalidation.value.didPersist)
    let cached = await cache.loadMostRecentPolicyDocumentSnapshot()
    #expect(cached == nil)

    let rejected = await cache.cachePolicyDocument(
      canvasId: "canvas-stale",
      document: staleDocument,
      sourceGeneration: 0
    )
    #expect(!rejected.didPersist)
  }
}

private actor PolicyCacheFirstSaveGate {
  private(set) var saveEntryCount = 0
  private var firstSaveContinuation: CheckedContinuation<Void, Never>?
  private var arrivalContinuations: [CheckedContinuation<Void, Never>] = []

  func waitIfFirstSave() async {
    saveEntryCount += 1
    guard saveEntryCount == 1 else { return }
    let arrivals = arrivalContinuations
    arrivalContinuations.removeAll()
    for arrival in arrivals {
      arrival.resume()
    }
    await withCheckedContinuation { continuation in
      firstSaveContinuation = continuation
    }
  }

  func waitUntilFirstSaveIsBlocked() async {
    guard saveEntryCount == 0 else { return }
    await withCheckedContinuation { continuation in
      arrivalContinuations.append(continuation)
    }
  }

  func releaseFirstSave() {
    firstSaveContinuation?.resume()
    firstSaveContinuation = nil
  }
}
