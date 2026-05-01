import XCTest

@testable import HarnessMonitor
import HarnessMonitorRegistry
import HarnessMonitorUIPreviewable
@testable import HarnessMonitorKit

@MainActor
final class HarnessMonitorMCPWindowCommandRegistrarTests: XCTestCase {
  func testRegistrarPublishesDisabledCommandsBeforeAnyOwnerInstalls() async {
    let service = HarnessMonitorMCPAccessibilityService()
    let registrar = HarnessMonitorMCPWindowCommandRegistrar(service: service)
    let workspaceIdentifier = HarnessMonitorAccessibility.windowMenuWorkspaceItem

    let workspaceCommand = await waitForWorkspaceCommand(in: service)
    XCTAssertEqual(workspaceCommand?.enabled, false)
    XCTAssertEqual(workspaceCommand?.actions, [.press])

    let result = await service.performSemanticAction(
      identifier: workspaceIdentifier,
      action: .press
    )
    XCTAssertEqual(result, .actionUnavailable)
    withExtendedLifetime(registrar) {}
  }

  func testRegistrarFallsBackToWorkspaceOwnerAndDisablesWhenLastOwnerLeaves() async {
    let service = HarnessMonitorMCPAccessibilityService()
    let registrar = HarnessMonitorMCPWindowCommandRegistrar(service: service)
    let workspaceIdentifier = HarnessMonitorAccessibility.windowMenuWorkspaceItem
    let workspaceOwner = UUID()
    let mainOwner = UUID()
    var openedWindowIDs: [String] = []

    await registrar.installOpenWindow(
      { windowID in
        openedWindowIDs.append("Workspace:\(windowID)")
      },
      ownerID: workspaceOwner
    )

    var workspaceCommand = await service.registry.element(identifier: workspaceIdentifier)
    XCTAssertEqual(workspaceCommand?.enabled, true)
    XCTAssertEqual(workspaceCommand?.actions, [.press])

    var result = await service.performSemanticAction(
      identifier: workspaceIdentifier,
      action: .press
    )
    XCTAssertEqual(result, .performed)
    XCTAssertEqual(openedWindowIDs, ["Workspace:\(HarnessMonitorWindowID.workspace)"])

    await registrar.installOpenWindow(
      { windowID in
        openedWindowIDs.append("Main:\(windowID)")
      },
      ownerID: mainOwner
    )

    result = await service.performSemanticAction(
      identifier: workspaceIdentifier,
      action: .press
    )
    XCTAssertEqual(result, .performed)
    XCTAssertEqual(openedWindowIDs.last, "Main:\(HarnessMonitorWindowID.workspace)")

    await registrar.uninstallOpenWindow(ownerID: mainOwner)

    result = await service.performSemanticAction(
      identifier: workspaceIdentifier,
      action: .press
    )
    XCTAssertEqual(result, .performed)
    XCTAssertEqual(openedWindowIDs.last, "Workspace:\(HarnessMonitorWindowID.workspace)")

    await registrar.uninstallOpenWindow(ownerID: workspaceOwner)

    workspaceCommand = await service.registry.element(identifier: workspaceIdentifier)
    XCTAssertEqual(workspaceCommand?.enabled, false)

    result = await service.performSemanticAction(
      identifier: workspaceIdentifier,
      action: .press
    )
    XCTAssertEqual(result, .actionUnavailable)
  }

  private func waitForWorkspaceCommand(
    in service: HarnessMonitorMCPAccessibilityService
  ) async -> RegistryElement? {
    let identifier = HarnessMonitorAccessibility.windowMenuWorkspaceItem
    for _ in 0..<10 {
      if let command = await service.registry.element(identifier: identifier) {
        return command
      }
      await Task.yield()
    }
    return await service.registry.element(identifier: identifier)
  }
}
