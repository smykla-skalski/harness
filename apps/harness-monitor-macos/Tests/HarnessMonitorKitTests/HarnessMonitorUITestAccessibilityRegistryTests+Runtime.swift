import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension HarnessMonitorUITestAccessibilityRegistryTests {
  @MainActor
  @Test("Harness MCP tracked elements register in the shared runtime registry")
  func harnessTrackedElementsRegisterInRuntimeRegistry() async {
    let registry = HarnessMonitorMCPAccessibilityService.shared.registry
    let identifier = "harness.test.runtime-registration"

    await registry.unregisterElement(identifier: identifier)

    let host = NSHostingView(
      rootView: Text("Pointer Target")
        .harnessTrackMCPElement(identifier, kind: .row, label: "Pointer Target")
    )
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    host.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()

    #expect(
      await waitUntil {
        await registry.element(identifier: identifier) != nil
      }
    )

    let element = await registry.element(identifier: identifier)
    #expect(element?.label == "Pointer Target")
    #expect((element?.frame.width ?? 0) > 0)
    #expect((element?.frame.height ?? 0) > 0)

    window.contentView = nil
    host.removeFromSuperview()

    #expect(
      await waitUntil {
        await registry.element(identifier: identifier) == nil
      }
    )
  }

  @MainActor
  @Test("Harness MCP tracked press actions execute through the shared runtime service")
  func harnessTrackedPressActionsExecuteThroughTheSharedRuntimeService() async {
    let service = HarnessMonitorMCPAccessibilityService.shared
    let registry = service.registry
    let identifier = "harness.test.semantic-press"
    let probe = AccessibilityRegistrySemanticPressProbe()

    await registry.unregisterElement(identifier: identifier)

    let host = NSHostingView(
      rootView: Button("Semantic Press") {}
        .harnessMCPButton(
          identifier,
          label: "Semantic Press",
          pressAction: { probe.recordPress() }
        )
    )
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    host.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()

    #expect(
      await waitUntil {
        await registry.element(identifier: identifier)?.actions == [.press]
      }
    )

    let result = await service.performSemanticAction(identifier: identifier, action: .press)
    #expect(result == .performed)
    #expect(probe.pressCount == 1)
  }
}
