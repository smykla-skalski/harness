import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

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

  @Test("agent launch defaults round-trip ACP storage keys")
  func agentLaunchDefaultsRoundTripAcpSelections() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let selection = AgentLaunchSelection.acp("copilot")

    HarnessMonitorAgentLaunchDefaults.persist(selection, userDefaults: defaults)

    #expect(
      HarnessMonitorAgentLaunchDefaults.preferredSelection(userDefaults: defaults) == selection
    )
  }

  @Test("agent launch defaults fall back to first provider when persisted selection is malformed")
  func agentLaunchDefaultsFallBackOnMalformedPersistedSelection() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defaults.set("managed:", forKey: HarnessMonitorAgentLaunchDefaults.preferredSelectionKey)

    #expect(
      HarnessMonitorAgentLaunchDefaults.preferredSelection(userDefaults: defaults)
        == .tui(.codex)
    )
  }

  @Test("agent launch defaults fall back to first provider when no preference is stored")
  func agentLaunchDefaultsFallBackWhenPreferenceMissing() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)

    #expect(
      HarnessMonitorAgentLaunchDefaults.preferredSelection(userDefaults: defaults)
        == .tui(.codex)
    )
  }

  @Test("agent launch defaults migrate legacy Copilot terminal to first provider once")
  func agentLaunchDefaultsMigrateLegacyCopilotTerminalDefaultOnce() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defaults.set(
      AgentLaunchSelection.tui(.copilot).storageKey,
      forKey: HarnessMonitorAgentLaunchDefaults.preferredSelectionKey
    )

    #expect(
      HarnessMonitorAgentLaunchDefaults.preferredSelection(userDefaults: defaults)
        == .tui(.codex)
    )
    #expect(
      !HarnessMonitorAgentLaunchDefaults.hasExplicitPreferredSelection(userDefaults: defaults))

    HarnessMonitorAgentLaunchDefaults.persist(.tui(.copilot), userDefaults: defaults)

    #expect(
      HarnessMonitorAgentLaunchDefaults.preferredSelection(userDefaults: defaults) == .tui(.copilot)
    )
    #expect(HarnessMonitorAgentLaunchDefaults.hasExplicitPreferredSelection(userDefaults: defaults))
  }

  @Test("launch presets ignore legacy Copilot terminal provider while preserving other fields")
  func launchPresetsIgnoreLegacyCopilotTerminalProvider() throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let snapshot = LaunchPresetSnapshot(
      mode: .terminal,
      providerStorageKey: AgentLaunchSelection.tui(.copilot).storageKey,
      rows: 40,
      cols: 100
    )
    defaults.set(LaunchPresetDefaults.encode(snapshot), forKey: LaunchPresetDefaults.storageKey)

    let restored = try #require(LaunchPresetDefaults.read(userDefaults: defaults))

    #expect(restored.providerStorageKey == nil)
    #expect(restored.rows == 40)
    #expect(restored.cols == 100)
    #expect(!LaunchPresetDefaults.blocksInitialAcpDefault(restored))
  }
}
