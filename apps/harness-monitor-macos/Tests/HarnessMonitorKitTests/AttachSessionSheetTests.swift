import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Attach session sheet")
@MainActor
struct AttachSessionSheetTests {
  private func makeStore() -> HarnessMonitorStore {
    HarnessMonitorStore(daemonController: RecordingDaemonController())
  }

  @Test("PresentedSheet.attachExternal id uses bookmark id")
  func presentedSheetIdentity() {
    let preview: SessionDiscoveryProbe.Preview? = nil
    let sheet = HarnessMonitorStore.PresentedSheet.attachExternal(
      bookmarkId: "B-xyz",
      preview: preview
    )
    #expect(sheet.id == "attachExternal:B-xyz")
  }

  @Test("PresentedSheet.attachExternal with preview has stable id")
  func presentedSheetIdentityWithPreview() {
    let preview = SessionDiscoveryProbe.Preview(
      sessionId: "abc12345",
      projectName: "demo",
      title: "Test",
      createdAt: Date(timeIntervalSince1970: 0),
      originPath: "/tmp/nope",
      originReachable: false,
      sessionRoot: URL(fileURLWithPath: "/tmp/session")
    )
    let sheet = HarnessMonitorStore.PresentedSheet.attachExternal(
      bookmarkId: "B-abc",
      preview: preview
    )
    #expect(sheet.id == "attachExternal:B-abc")
  }

  @Test("failureTitle returns correct label for each case")
  func failureTitleLabels() {
    let store = makeStore()
    let view = AttachSessionSheetView(store: store, bookmarkID: "B-1", preview: nil)

    #expect(view.failureTitle(.notAHarnessSession(reason: "x")) == "Not a harness session")
    let versionTitle = view.failureTitle(.unsupportedSchemaVersion(found: 3, supported: 9))
    #expect(versionTitle == "Unsupported schema version")
    let projectTitle = view.failureTitle(.belongsToAnotherProject(expected: "a", found: "b"))
    #expect(projectTitle == "Belongs to another project")
    #expect(view.failureTitle(.alreadyAttached(sessionId: "s1")) == "Already attached")
  }

  @Test("failureMessage formats values into message strings")
  func failureMessageFormatting() {
    let store = makeStore()
    let view = AttachSessionSheetView(store: store, bookmarkID: "B-1", preview: nil)

    #expect(
      view.failureMessage(.notAHarnessSession(reason: "missing state.json"))
        == "missing state.json"
    )
    let versionMsg = view.failureMessage(.unsupportedSchemaVersion(found: 3, supported: 9))
    #expect(versionMsg == "Schema version 3 is not supported. This Monitor expects v9.")
    let projectMsg = view.failureMessage(
      .belongsToAnotherProject(expected: "/proj/a", found: "/proj/b")
    )
    #expect(projectMsg == "Expected origin /proj/a, found /proj/b.")
    #expect(
      view.failureMessage(.alreadyAttached(sessionId: "abc12345"))
        == "Session abc12345 is already attached."
    )
  }
}
