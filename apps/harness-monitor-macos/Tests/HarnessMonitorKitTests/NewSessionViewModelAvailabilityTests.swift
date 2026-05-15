import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
extension NewSessionViewModelTests {
  // MARK: - availableBookmarks

  @Test("availableBookmarks returns only projectRoot bookmarks from empty store")
  func availableBookmarksFiltersToProjectRoot() async {
    let vm = makeNewSessionViewModel()

    let bookmarks = await vm.availableBookmarks()

    #expect(bookmarks.isEmpty)
  }

  @Test("availableBookmarks drops the UI test seed bookmark outside UI test stores")
  func availableBookmarksDropsUITestSeedOutsideUITestStores() async throws {
    let containerURL = try makeBookmarkContainer()
    try writeBookmarksFile(
      """
        {
          "schemaVersion": 1,
          "bookmarks": [
            {
              "id": "B-preseed",
              "kind": "project-root",
              "displayName": "Sample Project Folder",
              "lastResolvedPath": "/tmp/sample",
              "bookmarkData": "AA==",
              "createdAt": "2024-01-01T00:00:00Z",
              "lastAccessedAt": "2024-01-01T00:00:00Z",
              "staleCount": 0
            },
            {
              "id": "B-real",
              "kind": "project-root",
              "displayName": "harness",
              "lastResolvedPath": "/tmp/harness",
              "bookmarkData": "AA==",
              "createdAt": "2024-01-01T00:00:00Z",
              "lastAccessedAt": "2024-01-01T00:00:00Z",
              "staleCount": 0
            }
          ]
        }
      """,
      containerURL: containerURL
    )

    let vm = makeNewSessionViewModel(
      bookmarkStore: BookmarkStore(containerURL: containerURL)
    )

    let bookmarks = await vm.availableBookmarks()

    #expect(bookmarks.count == 1)
    #expect(bookmarks.first?.id == "B-real")
    #expect(bookmarks.first?.displayName == "harness")
  }

  // MARK: - lastError cleared on success

  @Test("lastError is nil after successful submit following a prior error")
  func lastErrorClearedAfterSuccess() async {
    let vm = makeNewSessionViewModel(
      bookmarkResolver: stubBookmarkResolver(id: "B-ok", path: "/tmp/ok")
    )
    vm.title = ""
    vm.selectedBookmarkId = "B-ok"
    _ = await vm.submit()
    #expect(vm.lastError == .validation(.titleRequired))

    vm.title = "Good Title"
    let result = await vm.submit()

    guard case .success = result else {
      Issue.record("Expected success, got \(result)")
      return
    }
    #expect(vm.lastError == nil)
  }

  // MARK: - Log sink

  @Test("submit emits started and succeeded logs on happy path")
  func submitEmitsStartedAndSucceededLogsOnHappyPath() async {
    let spy = SpyLogSink()
    let vm = makeNewSessionViewModel(
      bookmarkResolver: stubBookmarkResolver(id: "B-log", path: "/tmp/log"),
      logSink: spy
    )
    vm.title = "Logged Session"
    vm.selectedBookmarkId = "B-log"

    _ = await vm.submit()

    #expect(spy.infoMessages.contains("new-session submit started"))
    #expect(spy.infoMessages.contains { $0.hasPrefix("new-session submit succeeded id=") })
  }

  @Test("submit emits error log on daemon unreachable")
  func submitEmitsErrorLogOnDaemonUnreachable() async {
    let spy = SpyLogSink()
    let spyClient = SpyHarnessClient(error: URLError(.cannotConnectToHost))
    let vm = makeNewSessionViewModel(
      client: spyClient,
      bookmarkResolver: stubBookmarkResolver(id: "B-err", path: "/tmp/err"),
      logSink: spy
    )
    vm.title = "Fail Session"
    vm.selectedBookmarkId = "B-err"

    _ = await vm.submit()

    #expect(spy.errorMessages.contains { $0.contains("kind=daemonUnreachable") })
  }

  private func makeBookmarkContainer() throws -> URL {
    let containerURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("NewSessionViewModelTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
    return containerURL
  }

  private func writeBookmarksFile(_ json: String, containerURL: URL) throws {
    let sandboxURL = containerURL.appendingPathComponent("sandbox", isDirectory: true)
    try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: sandboxURL.appendingPathComponent("bookmarks.json"))
  }
}
