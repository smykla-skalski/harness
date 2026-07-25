import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Repository working copy inventory")
struct RepositoryWorkingCopyInventoryTests {
  private func entry(
    _ repository: String,
    sizeBytes: UInt64 = 1024,
    segment: String? = nil
  ) -> WorkingCopyListEntry {
    let key = segment ?? repository.replacingOccurrences(of: "/", with: "__").lowercased()
    return WorkingCopyListEntry(
      repoFullName: repository,
      repoKeySegment: key,
      path: "/copies/\(key)",
      sizeBytes: sizeBytes,
      createdAt: "2026-07-01T00:00:00Z",
      lastUsedAt: "2026-07-02T00:00:00Z"
    )
  }

  @Test("A copy whose repository is no longer monitored stays reclaimable")
  func unmonitoredCopyIsListed() {
    let inventory = RepositoryWorkingCopyInventory(
      copies: [entry("owner/dropped")],
      monitoredRepositories: ["owner/kept"],
      associatedRepositories: []
    )
    #expect(inventory.unlisted.map(\.repoFullName) == ["owner/dropped"])
  }

  @Test("A monitored repository keeps its copy on its own row")
  func monitoredCopyIsNotDuplicated() {
    let inventory = RepositoryWorkingCopyInventory(
      copies: [entry("owner/kept")],
      monitoredRepositories: ["owner/kept"],
      associatedRepositories: []
    )
    #expect(inventory.unlisted.isEmpty)
    #expect(inventory.byRepository["owner/kept"]?.repoFullName == "owner/kept")
  }

  @Test("A repository bound to a picked folder still shows its copy")
  func associatedRepositoryCopyIsListed() {
    let inventory = RepositoryWorkingCopyInventory(
      copies: [entry("owner/bound")],
      monitoredRepositories: ["owner/bound"],
      associatedRepositories: ["owner/bound"]
    )
    // The row shows Remove for the folder binding, so nothing there would
    // reclaim the copy the daemon is still holding.
    #expect(inventory.unlisted.map(\.repoFullName) == ["owner/bound"])
  }

  @Test("Repository matching ignores case and surrounding space")
  func matchingIsNormalized() {
    let inventory = RepositoryWorkingCopyInventory(
      copies: [entry("Owner/Mixed")],
      monitoredRepositories: [" owner/mixed "],
      associatedRepositories: []
    )
    #expect(inventory.unlisted.isEmpty)
    #expect(inventory.byRepository["owner/mixed"]?.repoFullName == "Owner/Mixed")
  }

  @Test("Listed copies read largest first")
  func listedCopiesAreSortedBySize() {
    let inventory = RepositoryWorkingCopyInventory(
      copies: [
        entry("owner/small", sizeBytes: 10),
        entry("owner/large", sizeBytes: 5000),
        entry("owner/medium", sizeBytes: 900),
      ],
      monitoredRepositories: [],
      associatedRepositories: []
    )
    #expect(
      inventory.unlisted.map(\.repoFullName) == ["owner/large", "owner/medium", "owner/small"]
    )
  }

  @Test("Equal sizes fall back to the repository name")
  func equalSizesAreOrderedByName() {
    let inventory = RepositoryWorkingCopyInventory(
      copies: [entry("owner/b"), entry("owner/a")],
      monitoredRepositories: [],
      associatedRepositories: []
    )
    #expect(inventory.unlisted.map(\.repoFullName) == ["owner/a", "owner/b"])
  }
}
