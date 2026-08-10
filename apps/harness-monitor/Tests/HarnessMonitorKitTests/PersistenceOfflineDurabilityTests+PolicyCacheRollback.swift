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
}
