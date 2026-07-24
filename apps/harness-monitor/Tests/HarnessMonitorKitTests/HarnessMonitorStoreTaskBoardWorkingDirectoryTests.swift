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
}
