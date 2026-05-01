import AppKit
import Darwin
import Foundation
import HarnessMonitorRegistry
import HarnessMonitorUIPreviewable
import SwiftUI
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorMCPContractTests {
  @Test("disabled reconciliation removes a stale socket path left behind by a dead process")
  func disabledReconciliationRemovesStaleSocketPath() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("mcp.sock", isDirectory: false)
    FileManager.default.createFile(atPath: socketURL.path, contents: Data("stale".utf8))
    #expect(FileManager.default.fileExists(atPath: socketURL.path))

    let service = HarnessMonitorMCPAccessibilityService(
      socketPathResolver: { socketURL }
    )

    await service.setEnabled(false)

    #expect(FileManager.default.fileExists(atPath: socketURL.path) == false)
    #expect(service.runtimeState == .disabled)
  }

  @Test("enabled reconciliation binds a healthy registry socket")
  func enabledReconciliationBindsHealthyRegistrySocket() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("mcp.sock", isDirectory: false)

    let service = HarnessMonitorMCPAccessibilityService(
      socketPathResolver: { socketURL }
    )
    await service.setEnabled(true)
    defer { Task { await service.setEnabled(false) } }

    try await waitForSocket(at: socketURL.path, timeout: 2)
    let response = try sendLine("{\"id\":1,\"op\":\"ping\"}", toSocketAt: socketURL.path)

    #expect(response.contains("\"ok\":true"))
    #expect(service.runtimeState == .healthy(socketPath: socketURL.path))
  }

  @Test("semantic actions round-trip over the live registry socket")
  func semanticActionsRoundTripOverTheLiveRegistrySocket() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("mcp.sock", isDirectory: false)
    let service = HarnessMonitorMCPAccessibilityService(
      socketPathResolver: { socketURL }
    )
    let socketClient = RegistrySocketClient(timeout: 2)
    let identifier = "harness.test.live-semantic-press"
    let probe = MCPContractSemanticPressProbe()

    await service.setEnabled(true)
    defer { Task { await service.setEnabled(false) } }
    try await waitForSocket(at: socketURL.path, timeout: 2)
    await service.registry.unregisterElement(identifier: identifier)

    let host = NSHostingView(
      rootView: Button("Semantic Press") {}
        .harnessMCPButton(
          identifier,
          label: "Semantic Press",
          service: service,
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

    try await waitForSocketResponse(at: socketURL.path, timeout: 2) { response in
      response.contains(#""identifier":"\#(identifier)""#)
        && response.contains(#""actions":["press"]"#)
    }

    let ack = try await socketClient.performAction(
      identifier: identifier,
      action: .press,
      toSocketAt: socketURL.path
    )

    #expect(ack.applied == true)
    #expect(probe.pressCount == 1)
  }

  @Test("persistent semantic elements register live menu item actions")
  func persistentSemanticElementsRegisterLiveMenuItemActions() async {
    let service = HarnessMonitorMCPAccessibilityService()
    let identifier = "harness.test.window-menu.workspace"
    let probe = MCPContractSemanticPressProbe()
    let semanticActions = RegistryTrackedSemanticActions(press: { probe.recordPress() })
    let element = RegistryElement(
      identifier: identifier,
      label: "Workspace",
      hint: "Open the Workspace window.",
      kind: .menuItem,
      frame: RegistryRect(x: 0, y: 0, width: 0, height: 0)
    )

    await service.registerPersistentSemanticElement(
      element,
      semanticActions: semanticActions
    )

    let stored = await service.registry.element(identifier: identifier)
    #expect(stored?.kind == .menuItem)
    #expect(stored?.actions == [.press])

    let result = await service.performSemanticAction(identifier: identifier, action: .press)
    #expect(result == .performed)
    #expect(probe.pressCount == 1)

    await service.unregisterPersistentSemanticElement(identifier: identifier)
    let removed = await service.registry.element(identifier: identifier)
    #expect(removed == nil)
  }

  @Test("enabled reconciliation reuses a compatible registry socket and forwards local snapshots")
  func enabledReconciliationReusesCompatibleRegistrySocket() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("mcp.sock", isDirectory: false)
    let hostService = HarnessMonitorMCPAccessibilityService(socketPathResolver: { socketURL })
    let reusedService = HarnessMonitorMCPAccessibilityService(socketPathResolver: { socketURL })

    await hostService.setEnabled(true)
    defer {
      Task {
        await reusedService.setEnabled(false)
        await hostService.setEnabled(false)
      }
    }
    try await waitForSocket(at: socketURL.path, timeout: 2)

    await hostService.registry.registerElement(
      RegistryElement(
        identifier: "host.refresh",
        kind: .button,
        frame: RegistryRect(x: 10, y: 20, width: 24, height: 24),
        windowID: 10
      )
    )

    await reusedService.setEnabled(true)
    await reusedService.registry.registerElement(
      RegistryElement(
        identifier: "client.refresh",
        kind: .button,
        frame: RegistryRect(x: 40, y: 60, width: 24, height: 24),
        windowID: 20
      )
    )

    try await waitForSocketResponse(at: socketURL.path, timeout: 2) { response in
      response.contains("\"identifier\":\"host.refresh\"")
        && response.contains("\"identifier\":\"client.refresh\"")
    }

    #expect(reusedService.isRunning == false)
    #expect(reusedService.runtimeState == .healthy(socketPath: socketURL.path))
  }

  @Test("enabled reconciliation replaces an incompatible socket and old host reregisters")
  func enabledReconciliationReplacesIncompatibleSocketAndReregisters() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("mcp.sock", isDirectory: false)
    let legacyHost = HarnessMonitorMCPAccessibilityService(
      socketPathResolver: { socketURL },
      pingInfoProvider: {
        PingResult(
          protocolVersion: registryProtocolVersion,
          appVersion: "30.31.0",
          bundleIdentifier: "io.harnessmonitor.app",
          capabilities: [.replacementNotice]
        )
      },
      startupProbeDelay: .milliseconds(20),
      startupProbeCount: 50
    )
    let replacementHost = HarnessMonitorMCPAccessibilityService(
      socketPathResolver: { socketURL },
      pingInfoProvider: {
        PingResult(
          protocolVersion: registryProtocolVersion,
          appVersion: "30.32.0",
          bundleIdentifier: "io.harnessmonitor.app",
          capabilities: [
            .clientSnapshots,
            .clientSnapshotLeases,
            .replacementNotice,
            .semanticActions,
          ]
        )
      },
      startupProbeDelay: .milliseconds(20),
      startupProbeCount: 50
    )

    await legacyHost.setEnabled(true)
    defer {
      Task {
        await legacyHost.setEnabled(false)
        await replacementHost.setEnabled(false)
      }
    }
    try await waitForSocket(at: socketURL.path, timeout: 2)

    await legacyHost.registry.registerElement(
      RegistryElement(
        identifier: "legacy.refresh",
        kind: .button,
        frame: RegistryRect(x: 10, y: 20, width: 24, height: 24),
        windowID: 10
      )
    )

    await replacementHost.setEnabled(true)
    await replacementHost.registry.registerElement(
      RegistryElement(
        identifier: "replacement.refresh",
        kind: .button,
        frame: RegistryRect(x: 40, y: 60, width: 24, height: 24),
        windowID: 20
      )
    )

    try await waitForSocketResponse(at: socketURL.path, timeout: 2) { response in
      response.contains("\"identifier\":\"legacy.refresh\"")
        && response.contains("\"identifier\":\"replacement.refresh\"")
    }

    #expect(replacementHost.isRunning == true)
    #expect(replacementHost.runtimeState == .healthy(socketPath: socketURL.path))
    #expect(legacyHost.isRunning == false)
  }

  @Test("enabled reconciliation rejects foreign bundle registry hosts")
  func enabledReconciliationRejectsForeignBundleRegistryHosts() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("mcp.sock", isDirectory: false)
    let foreignHost = HarnessMonitorMCPAccessibilityService(
      socketPathResolver: { socketURL },
      pingInfoProvider: {
        PingResult(
          protocolVersion: registryProtocolVersion,
          appVersion: "30.32.0",
          bundleIdentifier: "io.foreign.registry",
          capabilities: [
            .clientSnapshots,
            .clientSnapshotLeases,
            .replacementNotice,
            .semanticActions,
          ]
        )
      }
    )
    let localService = HarnessMonitorMCPAccessibilityService(socketPathResolver: { socketURL })

    await foreignHost.setEnabled(true)
    defer {
      Task {
        await localService.setEnabled(false)
        await foreignHost.setEnabled(false)
      }
    }
    try await waitForSocket(at: socketURL.path, timeout: 2)

    await localService.setEnabled(true)

    #expect(localService.isRunning == false)
    guard case .degraded(let socketPath, let reason) = localService.runtimeState else {
      Issue.record("expected degraded runtime state, got \(localService.runtimeState)")
      return
    }
    #expect(socketPath == socketURL.path)
    #expect(reason.contains("io.foreign.registry"))
  }

  @Test("real service degrades when the socket path cannot be resolved")
  func realServiceDegradesWhenSocketPathCannotBeResolved() async {
    let service = HarnessMonitorMCPAccessibilityService(socketPathResolver: { nil })

    await service.setEnabled(true)

    #expect(
      service.runtimeState
        == .degraded(socketPath: nil, reason: "cannot resolve app-group container")
    )
  }

  @Test("late replacement delivery after disable does not resurrect remote mode")
  func lateReplacementDeliveryAfterDisableDoesNotResurrectRemoteMode() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("mcp.sock", isDirectory: false)

    let service = HarnessMonitorMCPAccessibilityService(
      socketPathResolver: { socketURL },
      pingInfoProvider: {
        PingResult(
          protocolVersion: registryProtocolVersion,
          appVersion: "30.31.2",
          bundleIdentifier: "io.harnessmonitor.app",
          capabilities: [
            .clientSnapshots,
            .clientSnapshotLeases,
            .replacementNotice,
            .semanticActions,
          ]
        )
      }
    )
    let notice = RegistryReplacementNotice(
      socketPath: socketURL.path,
      protocolVersion: registryProtocolVersion,
      appVersion: "30.32.0",
      bundleIdentifier: "io.harnessmonitor.app",
      message: "replacement incoming"
    )

    let disposition = await service.handleReplacementNotice(notice)
    #expect(disposition.ack.applied == true)

    await service.setEnabled(false)
    if let onDelivered = disposition.onDelivered {
      await onDelivered()
    } else {
      Issue.record("expected replacement delivery callback")
    }

    #expect(service.runtimeState == .disabled)
    #expect(service.isRunning == false)
    #expect(await service.probeRuntimeState() == .disabled)
  }
}
