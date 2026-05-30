import AppKit
import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

final class AppOpenAnythingPaletteWindowTests: XCTestCase {
  @MainActor
  func testShowFitsPanelHeightBeforeItBecomesVisible() async {
    let previousAllowsAutomaticWindowTabbing = NSWindow.allowsAutomaticWindowTabbing
    NSWindow.allowsAutomaticWindowTabbing = false
    closeExistingPalettePanels()
    defer {
      closeExistingPalettePanels()
      NSWindow.allowsAutomaticWindowTabbing = previousAllowsAutomaticWindowTabbing
    }

    let anchor = makeAnchorWindow(origin: NSPoint(x: 120, y: 220))
    defer {
      anchor.orderOut(nil)
    }

    anchor.makeKeyAndOrderFront(nil)
    drainMainRunLoop()

    let controller = await makeController()
    controller.show(scope: nil, contextDomain: nil, restoreLastQuery: false)

    guard let panel = palettePanel else {
      XCTFail("Expected Open Anything panel to exist")
      return
    }

    XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01)
    XCTAssertLessThan(panel.frame.height, OpenAnythingPaletteConstants.maxHeight - 0.5)
    XCTAssertEqual(panel.contentLayoutRect.height, panel.frame.height, accuracy: 0.5)
    guard let hostedHeight = panel.contentView?.subviews.first?.frame.height,
          let contentHeight = panel.contentView?.frame.height
    else {
      XCTFail("Expected hosting view to fill the palette content view")
      return
    }
    XCTAssertEqual(hostedHeight, contentHeight, accuracy: 0.5)
  }

  @MainActor
  func testReopenKeepsSettledVerticalPosition() async {
    let previousAllowsAutomaticWindowTabbing = NSWindow.allowsAutomaticWindowTabbing
    NSWindow.allowsAutomaticWindowTabbing = false
    closeExistingPalettePanels()
    defer {
      closeExistingPalettePanels()
      NSWindow.allowsAutomaticWindowTabbing = previousAllowsAutomaticWindowTabbing
    }

    let anchor = makeAnchorWindow(origin: NSPoint(x: 180, y: 260))
    defer {
      anchor.orderOut(nil)
    }

    anchor.makeKeyAndOrderFront(nil)
    drainMainRunLoop()

    let controller = await makeController()
    controller.show(scope: nil, contextDomain: nil, restoreLastQuery: false)
    drainMainRunLoop()

    guard let panel = palettePanel else {
      XCTFail("Expected Open Anything panel to exist")
      return
    }

    let firstFrame = panel.frame
    controller.hide()
    drainMainRunLoop()

    controller.show(scope: nil, contextDomain: nil, restoreLastQuery: false)
    drainMainRunLoop()

    let secondFrame = panel.frame
    XCTAssertEqual(secondFrame.minY, firstFrame.minY, accuracy: 0.5)
    XCTAssertEqual(secondFrame.maxY, firstFrame.maxY, accuracy: 0.5)
  }

  @MainActor
  private func makeController() async -> OpenAnythingPaletteWindowController {
    let model = Self.makeModel()
    await model.replaceCorpus(Self.sampleRecords)
    let controller = OpenAnythingPaletteWindowController(model: model)
    controller.bindExecutor { _ in }
    drainMainRunLoop()
    return controller
  }

  @MainActor private var palettePanel: OpenAnythingFloatingPanel? {
    NSApp.windows.compactMap { $0 as? OpenAnythingFloatingPanel }.last
  }

  @MainActor
  private func closeExistingPalettePanels() {
    for panel in NSApp.windows.compactMap({ $0 as? OpenAnythingFloatingPanel }).reversed() {
      panel.orderOut(nil)
    }
  }

  @MainActor
  private func makeAnchorWindow(origin: NSPoint) -> NSWindow {
    NSWindow(
      contentRect: NSRect(origin: origin, size: NSSize(width: 960, height: 640)),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
  }

  @MainActor
  private func drainMainRunLoop() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
  }

  @MainActor
  private static func makeModel() -> OpenAnythingPaletteModel {
    let suiteName = "AppOpenAnythingPaletteWindowTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      preconditionFailure("Failed to create Open Anything test defaults")
    }
    return OpenAnythingPaletteModel(
      recency: OpenAnythingRecencyStore(defaults: defaults, key: "recency"),
      pins: OpenAnythingPinStore(defaults: defaults, key: "pins")
    )
  }

  private static let sampleRecords: [OpenAnythingRecord] = [
    OpenAnythingRecord(
      id: "action.refresh",
      domain: .actions,
      target: .action(.refresh),
      title: "Refresh",
      isSuggested: true
    ),
    OpenAnythingRecord(
      id: "action.openBoard",
      domain: .actions,
      target: .action(.openTaskBoard),
      title: "Open Board",
      subtitle: "Navigate",
      isSuggested: true
    ),
    OpenAnythingRecord(
      id: "session.alpha",
      domain: .sessions,
      target: .session(sessionID: "alpha"),
      title: "Alpha Session",
      subtitle: "Project · main",
      isSuggested: true
    ),
  ]
}
