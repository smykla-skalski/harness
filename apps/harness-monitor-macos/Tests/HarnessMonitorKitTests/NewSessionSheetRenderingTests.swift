import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("NewSessionSheetRendering")
final class NewSessionSheetRenderingTests {
  // MARK: - Helpers

  private func makeStore() -> HarnessMonitorStore {
    HarnessMonitorStore(daemonController: RecordingDaemonController())
  }

  private func makeBookmarkStore() -> BookmarkStore {
    BookmarkStore(containerURL: FileManager.default.temporaryDirectory)
  }

  private func makeViewModel(
    bookmarkResolver: NewSessionViewModel.BookmarkResolver? = nil
  ) -> NewSessionViewModel {
    NewSessionViewModel(
      store: makeStore(),
      bookmarkStore: makeBookmarkStore(),
      client: RecordingHarnessClient(),
      isSandboxed: { true },
      bookmarkResolver: bookmarkResolver
    )
  }

  private func failingResolver(
    error: any Error
  ) -> NewSessionViewModel.BookmarkResolver {
    { _ in throw error }
  }

  // MARK: - Initial form state

  @Test("initial form has empty fields and no selection")
  func testInitialFormHasEmptyFields() async {
    let viewModel = makeViewModel()

    #expect(viewModel.title.isEmpty)
    #expect(viewModel.context.isEmpty)
    #expect(viewModel.baseRef.isEmpty)
    #expect(viewModel.selectedBookmarkId == nil)
    #expect(viewModel.isSubmitting == false)
    #expect(viewModel.lastError == nil)
  }

  // MARK: - Error banner

  @Test("bookmarkRevoked error surfaces on lastError after submit")
  func testErrorBannerIdentifiesRevokedBookmark() async {
    let bookmarkError = BookmarkStoreError.unresolvable(
      id: "B-x",
      underlying: "could not resolve security-scoped bookmark"
    )
    let viewModel = makeViewModel(
      bookmarkResolver: failingResolver(error: bookmarkError)
    )
    viewModel.title = "Test Session"
    viewModel.selectedBookmarkId = "B-x"

    let result = await viewModel.submit()

    #expect(result == .failure(.bookmarkRevoked(id: "B-x")))
    #expect(viewModel.lastError == .bookmarkRevoked(id: "B-x"))
  }
}
