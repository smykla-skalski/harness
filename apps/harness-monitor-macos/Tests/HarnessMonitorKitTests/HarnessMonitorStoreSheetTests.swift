import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Store sheet presentation")
struct HarnessMonitorStoreSheetTests {
  @Test("presentedSheet starts as nil")
  func presentedSheetStartsNil() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    #expect(store.presentedSheet == nil)
  }

  @Test("presentSendSignalSheet sets the sheet when online with a selected session")
  func presentSendSignalSheetSetsSheet() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.presentSendSignalSheet(agentID: "leader-claude")

    #expect(store.presentedSheet == .sendSignal(agentID: "leader-claude"))
  }

  @Test("dismissSheet clears the sheet")
  func dismissSheetClearsSheet() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.presentSendSignalSheet(agentID: "leader-claude")

    store.dismissSheet()

    #expect(store.presentedSheet == nil)
  }

  @Test("presenting a new sheet replaces the previous one")
  func presentNewSheetReplacesPrevious() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.presentSendSignalSheet(agentID: "leader-claude")

    store.presentSendSignalSheet(agentID: "worker-codex")

    #expect(store.presentedSheet == .sendSignal(agentID: "worker-codex"))
  }

  @Test("presentSendSignalSheet is blocked when session is read-only")
  func presentSendSignalSheetBlockedWhenReadOnly() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    // No bootstrap means offline - isSessionReadOnly returns true.

    store.presentSendSignalSheet(agentID: "leader-claude")

    #expect(store.presentedSheet == nil)
    #expect(store.currentFailureFeedbackMessage != nil)
  }

  @Test("presentSendSignalSheet does nothing without a selected session")
  func presentSendSignalSheetRequiresSelectedSession() async {
    let store = await makeBootstrappedStore()
    // Online but no session selected.

    store.presentSendSignalSheet(agentID: "leader-claude")

    #expect(store.presentedSheet == nil)
  }

  @Test("PresentedSheet id is stable and unique per case")
  func presentedSheetIdIsStable() {
    let sheet1 = HarnessMonitorStore.PresentedSheet.sendSignal(agentID: "agent-a")
    let sheet2 = HarnessMonitorStore.PresentedSheet.sendSignal(agentID: "agent-b")

    #expect(sheet1.id == "sendSignal:agent-a")
    #expect(sheet2.id == "sendSignal:agent-b")
    #expect(sheet1.id != sheet2.id)
  }

  @Test("PresentedSheet cases are exhaustively matchable")
  func presentedSheetCasesAreExhaustivelyMatchable() {
    let sheet = HarnessMonitorStore.PresentedSheet.sendSignal(agentID: "agent-a")
    switch sheet {
    case .sendSignal: break
    case .newSession: break
    }
  }

  // MARK: - makeNewSessionViewModel

  @Test("makeNewSessionViewModel returns nil when client is nil")
  func makeNewSessionViewModelReturnsNilWhenClientIsNil() {
    // A freshly-constructed store has no client until bootstrap connects.
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    let viewModel = store.makeNewSessionViewModel()

    #expect(viewModel == nil)
  }

  @Test("makeNewSessionViewModel returns a view model after bootstrap")
  func makeNewSessionViewModelReturnsViewModelAfterBootstrap() async {
    let store = await makeBootstrappedStore()

    let viewModel = store.makeNewSessionViewModel()

    // bookmarkStore is available in DEBUG builds (temp dir fallback).
    // client is set by bootstrap. Both must be non-nil for a result.
    #expect(viewModel != nil)
  }
}
