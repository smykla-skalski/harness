import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Task board delivery working directory")
struct HarnessMonitorStoreTaskBoardWorkingDirectoryTests {
  @Test("Existing session needs no directory")
  func existingSessionNeedsNoDirectory() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let decision = await store.taskBoardDeliveryDirectory(
      hasExistingSession: true,
      executionRepository: "wd-existing/repo",
      globalProjectDir: "/tmp/global",
      daemonSandboxed: true
    )
    #expect(decision == .dispatch(projectDir: nil))
  }

  @Test("Sandboxed daemon receives the associated bookmark id")
  func sandboxedDaemonReceivesBookmarkID() async throws {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    try await store.repositoryDirectoryStore?.associate(
      repository: "wd-sandboxed/repo",
      bookmarkID: "B-sandboxed"
    )
    let decision = await store.taskBoardDeliveryDirectory(
      hasExistingSession: false,
      executionRepository: "WD-Sandboxed/Repo",
      globalProjectDir: "/tmp/global",
      daemonSandboxed: true
    )
    #expect(decision == .dispatch(projectDir: "B-sandboxed"))
  }

  @Test("Imported item without an association asks for a working directory")
  func importedItemWithoutAssociationNeedsWorkingDirectory() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let decision = await store.taskBoardDeliveryDirectory(
      hasExistingSession: false,
      executionRepository: "wd-unmapped/repo",
      globalProjectDir: "/tmp/global",
      daemonSandboxed: true
    )
    #expect(decision == .needsWorkingDirectory(repository: "wd-unmapped/repo"))
  }

  @Test("Create item without a repository keeps the global directory")
  func createItemWithoutRepositoryUsesGlobal() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let decision = await store.taskBoardDeliveryDirectory(
      hasExistingSession: false,
      executionRepository: nil,
      globalProjectDir: "/tmp/global",
      daemonSandboxed: true
    )
    #expect(decision == .dispatch(projectDir: "/tmp/global"))
  }

  @Test("Unresolved repositories exclude associated and existing-session items")
  func unresolvedRepositoriesExcludeAssociatedAndExisting() async throws {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    try await store.repositoryDirectoryStore?.associate(
      repository: "gather-mapped/repo",
      bookmarkID: "B-gather"
    )
    let items = [
      TaskBoardWorkingDirectoryResolver.ItemNeed(
        hasExistingSession: false, executionRepository: "gather-mapped/repo"),
      TaskBoardWorkingDirectoryResolver.ItemNeed(
        hasExistingSession: false, executionRepository: "gather-unmapped/repo"),
      TaskBoardWorkingDirectoryResolver.ItemNeed(
        hasExistingSession: false, executionRepository: "gather-unmapped/repo"),
      TaskBoardWorkingDirectoryResolver.ItemNeed(
        hasExistingSession: true, executionRepository: "gather-existing/repo"),
    ]
    let unresolved = await store.unresolvedTaskBoardRepositories(
      items: items,
      daemonSandboxed: true
    )
    #expect(unresolved == ["gather-unmapped/repo"])
  }

  @Test("A stale association that no longer resolves still needs a directory")
  func staleAssociationCountsAsUnresolved() async throws {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    try await store.repositoryDirectoryStore?.associate(
      repository: "stale-case/repo",
      bookmarkID: "B-does-not-resolve"
    )
    let items = [
      TaskBoardWorkingDirectoryResolver.ItemNeed(
        hasExistingSession: false, executionRepository: "stale-case/repo")
    ]
    // Non-sandboxed delivery must live-resolve the bookmark; a record that no
    // longer resolves has to re-prompt instead of being filtered out as
    // associated, which is what previously made Deliver silently no-op.
    let unresolved = await store.unresolvedTaskBoardRepositories(
      items: items,
      daemonSandboxed: false
    )
    #expect(unresolved == ["stale-case/repo"])
  }

  @Test("Choosing a folder associates it with the repository")
  func choosingFolderAssociatesRepository() async throws {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("resolve-assoc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let saved = await store.resolveRepositoryWorkingDirectory(
      repository: "Assoc-Case/Repo",
      from: .success([folder])
    )
    #expect(saved)
    let bookmarkID = await store.repositoryDirectoryStore?.bookmarkID(
      forRepository: "assoc-case/repo"
    )
    #expect(bookmarkID != nil)
  }

  @Test("Associations list repositories whose bookmark no longer resolves")
  func associationsIncludeUnresolvable() async throws {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    try await store.repositoryDirectoryStore?.associate(
      repository: "assoc-stale/repo",
      bookmarkID: "B-missing"
    )
    // The association record is present so Settings can still offer Remove, even
    // though the path omits it because the bookmark does not resolve.
    let associations = await store.repositoryDirectoryAssociations()
    #expect(associations.contains("assoc-stale/repo"))
    let paths = await store.repositoryWorkingDirectoryPaths()
    #expect(paths["assoc-stale/repo"] == nil)
  }

  @Test("Working directory paths resolve and clear per repository")
  func workingDirectoryPathsResolveAndClear() async throws {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("wd-paths-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    _ = await store.resolveRepositoryWorkingDirectory(
      repository: "paths-case/repo",
      from: .success([folder])
    )

    let paths = await store.repositoryWorkingDirectoryPaths()
    #expect(paths["paths-case/repo"] != nil)

    await store.removeRepositoryWorkingDirectory(repository: "Paths-Case/Repo")
    let afterRemove = await store.repositoryWorkingDirectoryPaths()
    #expect(afterRemove["paths-case/repo"] == nil)
  }

  @Test("A daemon-obtained working copy resolves delivery without prompting")
  func managedWorkingCopyResolvesDelivery() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let client = RecordingHarnessClient()
    client.setTaskBoardWorkingCopies([
      WorkingCopyListEntry(
        repoFullName: "obtained/repo",
        repoKeySegment: "seg__obtained/repo",
        path: "/managed/obtained/repo",
        sizeBytes: 2048,
        createdAt: "2026-07-24T00:00:00Z",
        lastUsedAt: "2026-07-24T00:00:00Z"
      )
    ])
    store.client = client
    let decision = await store.taskBoardDeliveryDirectory(
      hasExistingSession: false,
      executionRepository: "Obtained/Repo",
      globalProjectDir: "/tmp/global",
      daemonSandboxed: true
    )
    #expect(decision == .dispatch(projectDir: "/managed/obtained/repo"))
  }

  @Test("Unresolved repositories exclude ones with a working copy")
  func managedWorkingCopyExcludedFromUnresolved() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let client = RecordingHarnessClient()
    client.setTaskBoardWorkingCopies([
      WorkingCopyListEntry(
        repoFullName: "managed/repo",
        repoKeySegment: "seg__managed/repo",
        path: "/managed/managed/repo",
        sizeBytes: 2048,
        createdAt: "2026-07-24T00:00:00Z",
        lastUsedAt: "2026-07-24T00:00:00Z"
      )
    ])
    store.client = client
    let items = [
      TaskBoardWorkingDirectoryResolver.ItemNeed(
        hasExistingSession: false, executionRepository: "managed/repo"),
      TaskBoardWorkingDirectoryResolver.ItemNeed(
        hasExistingSession: false, executionRepository: "unmanaged/repo"),
    ]
    let unresolved = await store.unresolvedTaskBoardRepositories(
      items: items,
      daemonSandboxed: true
    )
    #expect(unresolved == ["unmanaged/repo"])
  }

  @Test("Obtain, list, and reclaim a working copy round-trip")
  func workingCopyStoreRoundTrip() async throws {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let client = RecordingHarnessClient()
    store.client = client

    let obtained = await store.obtainRepositoryWorkingCopy(repository: "round/trip")
    let entry = try #require(obtained)
    #expect(await store.listRepositoryWorkingCopies().contains { $0.repoFullName == "round/trip" })

    #expect(await store.deleteRepositoryWorkingCopy(repoKeySegment: entry.repoKeySegment))
    #expect(await store.listRepositoryWorkingCopies().isEmpty)
  }
}
