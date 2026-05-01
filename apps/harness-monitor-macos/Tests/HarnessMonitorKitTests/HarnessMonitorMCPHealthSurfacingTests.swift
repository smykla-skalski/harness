import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("MCP health surfacing")
struct HarnessMonitorMCPHealthSurfacingTests {
  @Test("Status snapshot describes degraded recovery")
  func statusSnapshotDescribesDegradedRecovery() {
    let status = HarnessMonitorMCPStatusSnapshot(
      runtimeState: .degraded(
        socketPath: "/tmp/harness-mcp.sock",
        reason: "listener never passed the local ping probe"
      ),
      recoveryStatus: HarnessMonitorMCPRecoveryStatus(
        completedRetryCount: 1,
        maximumRetryCount: 3,
        nextRetryDelay: .seconds(5)
      )
    )

    #expect(status.title == "Registry Host Degraded - Recovering")
    #expect(status.toolbarLabel == "Host Recovering")
    #expect(status.shouldShowChromeBanner)
    #expect(status.accessibilityLabel == "MCP accessibility registry host status")
    #expect(
      status.failureFeedbackMessage?
        .contains("Recovery continues in the background.") == true
    )
    #expect(
      status.failureFeedbackMessage?
        .contains("You can keep working while the registry retries in the background.") == true
    )
  }

  @Test("Store syncs MCP status into toolbar chrome diagnostics and feedback")
  func storeSyncsMCPStatusIntoVisibleSlices() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.toast.dedupeWindow = .zero
    let degraded = HarnessMonitorMCPStatusSnapshot(
      runtimeState: .degraded(
        socketPath: "/tmp/harness-mcp.sock",
        reason: "listener never passed the local ping probe"
      ),
      recoveryStatus: HarnessMonitorMCPRecoveryStatus(
        completedRetryCount: 0,
        maximumRetryCount: 3,
        nextRetryDelay: .seconds(5)
      )
    )

    store.updateMCPStatus(degraded)

    #expect(store.mcpStatus == degraded)
    #expect(store.contentUI.toolbar.mcpStatus == degraded)
    #expect(store.contentUI.chrome.mcpStatus == degraded)
    #expect(
      store.toast.activeFeedback.first?.message
        .contains("MCP registry host degraded:") == true
    )

    let snapshot = PreferencesDiagnosticsSnapshot(store: store)
    #expect(snapshot.mcpStatus == degraded)

    let healthy = HarnessMonitorMCPStatusSnapshot(
      runtimeState: .healthy(socketPath: "/tmp/harness-mcp.sock"),
      recoveryStatus: nil
    )
    #expect(healthy.detail.contains("This status covers the in-app registry host."))
    store.updateMCPStatus(healthy)

    #expect(store.contentUI.toolbar.mcpStatus == healthy)
    #expect(store.contentUI.chrome.mcpStatus == healthy)
    #expect(store.toast.activeFeedback.first?.message == "MCP registry host recovered and is ready.")
  }

  @Test("Store keeps one degraded failure toast across retry transitions")
  func storeDeduplicatesDegradedFeedbackAcrossRetryTransitions() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.toast.dedupeWindow = .zero

    let degraded = HarnessMonitorMCPStatusSnapshot(
      runtimeState: .degraded(
        socketPath: "/tmp/harness-mcp.sock",
        reason: "listener never passed the local ping probe"
      ),
      recoveryStatus: HarnessMonitorMCPRecoveryStatus(
        completedRetryCount: 0,
        maximumRetryCount: 3,
        nextRetryDelay: .seconds(5)
      )
    )

    store.updateMCPStatus(degraded)
    #expect(store.toast.activeFeedback.count == 1)

    store.updateMCPStatus(
      HarnessMonitorMCPStatusSnapshot(
        runtimeState: .starting(socketPath: "/tmp/harness-mcp.sock"),
        recoveryStatus: degraded.recoveryStatus
      )
    )
    #expect(store.toast.activeFeedback.count == 1)

    store.updateMCPStatus(
      HarnessMonitorMCPStatusSnapshot(
        runtimeState: .degraded(
          socketPath: "/tmp/harness-mcp.sock",
          reason: "listener never passed the local ping probe"
        ),
        recoveryStatus: HarnessMonitorMCPRecoveryStatus(
          completedRetryCount: 1,
          maximumRetryCount: 3,
          nextRetryDelay: .seconds(5)
        )
      )
    )
    #expect(store.toast.activeFeedback.count == 1)
  }

  @Test("Store does not emit extra failure feedback while disabling MCP")
  func storeDoesNotEmitExtraFailureFeedbackWhileDisabling() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.toast.dedupeWindow = .zero

    store.updateMCPStatus(
      HarnessMonitorMCPStatusSnapshot(
        runtimeState: .degraded(
          socketPath: "/tmp/harness-mcp.sock",
          reason: "listener never passed the local ping probe"
        ),
        recoveryStatus: HarnessMonitorMCPRecoveryStatus(
          completedRetryCount: 0,
          maximumRetryCount: 3,
          nextRetryDelay: .seconds(5)
        )
      )
    )
    #expect(store.toast.activeFeedback.count == 1)

    store.updateMCPStatus(
      HarnessMonitorMCPStatusSnapshot(
        runtimeState: .degraded(
          socketPath: "/tmp/harness-mcp.sock",
          reason: "listener never passed the local ping probe"
        ),
        recoveryStatus: nil
      )
    )
    #expect(store.toast.activeFeedback.count == 1)

    store.updateMCPStatus(
      HarnessMonitorMCPStatusSnapshot(
        runtimeState: .disabled,
        recoveryStatus: nil
      )
    )
    #expect(store.toast.activeFeedback.count == 1)
  }
}
