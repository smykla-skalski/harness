import AppKit
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task board native context menu")
struct TaskBoardNativeContextMenuTests {
  @Test("Secondary and Control clicks own the List cell context menu")
  func installsContextClickRecognizers() throws {
    let cell = NSTableCellView()
    cell.focusRingType = .default
    let container = NSView()
    let installer = TaskBoardCardContextMenu.InstallerView()
    let coordinator = TaskBoardCardContextMenu.Coordinator()
    cell.addSubview(container)
    container.addSubview(installer)

    coordinator.install(from: installer)

    let recognizers = cell.gestureRecognizers.compactMap {
      $0 as? NSClickGestureRecognizer
    }
    let secondaryClick = try #require(
      recognizers.first(where: { $0.buttonMask == 0x2 })
    )
    let controlClick = try #require(
      recognizers.first(where: { $0.buttonMask == 0x1 })
    )
    #expect(recognizers.count == 2)
    #expect(secondaryClick.delaysSecondaryMouseButtonEvents)
    #expect(controlClick.delaysPrimaryMouseButtonEvents)
    #expect((controlClick.delegate as AnyObject?) === coordinator)
    #expect(cell.focusRingType == .none)
    #expect(installer.hitTest(.zero) == nil)
    #expect(
      TaskBoardCardContextMenu.Coordinator.acceptsControlClick(
        modifierFlags: .control
      )
    )
    #expect(
      !TaskBoardCardContextMenu.Coordinator.acceptsControlClick(
        modifierFlags: []
      )
    )

    coordinator.detach()
    #expect(cell.gestureRecognizers.isEmpty)
    #expect(cell.focusRingType == .default)
  }
}
