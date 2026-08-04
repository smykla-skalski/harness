import AppKit
import HarnessMonitorKit
import SwiftUI

#Preview("Automation Controls — Mixed") {
  TaskBoardAutomationControlsPreview(mode: .mixed)
    .harnessPreviewSceneAppearance()
    .environment(\.controlActiveState, .key)
}

#Preview("Automation Controls — Kill Switch Engaged") {
  TaskBoardAutomationControlsPreview(mode: .killSwitchEngaged)
    .harnessPreviewSceneAppearance()
    .environment(\.controlActiveState, .key)
}

@MainActor
private struct TaskBoardAutomationControlsPreview: View {
  enum Mode {
    case mixed
    case killSwitchEngaged
  }

  @State private var store: HarnessMonitorStore
  @State private var state = TaskBoardAutomationInspectorState()

  init(mode: Mode) {
    _store = State(initialValue: Self.makeStore(mode: mode))
  }

  var body: some View {
    VStack(alignment: .leading) {
      TaskBoardAutomationSystemControls(
        store: store,
        state: state,
        presentation: Self.presentation,
        metrics: TaskBoardOverviewMetrics(fontScale: fontScale),
        isPresentationCurrent: true,
        actions: TaskBoardAutomationInspectorActions(store: store, state: state, isActive: true)
      )
    }
    .padding(24)
    .frame(width: 620, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        SleepPreventionToolbarButton(
          store: store,
          presentation: SleepPreventionToolbarPresentation(isEnabled: false)
        )
      }
      ToolbarSpacer(.fixed, placement: .primaryAction)
        .sharedBackgroundVisibility(.hidden)
      AutomationKillSwitchToolbarGroup(store: store)
    }
  }

  @Environment(\.fontScale)
  private var fontScale

  private static func makeStore(mode: Mode) -> HarnessMonitorStore {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .taskBoardBoardOnly)
    let isKillSwitchEngaged = mode == .killSwitchEngaged
    let triageEnabled = mode == .killSwitchEngaged
    let status = TaskBoardOrchestratorStatus(
      enabled: !isKillSwitchEngaged,
      running: false,
      settings: TaskBoardOrchestratorSettings(
        triageAutomationEnabled: triageEnabled,
        enabledWorkflows: [.defaultTask, .prReview],
        dryRunDefault: true,
        policyVersion: "preview"
      )
    )
    let workspace = PolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: "preview-policy",
      canvases: [],
      globalPolicyEnforcementEnabled: true,
      spawnKillSwitch: isKillSwitchEngaged
    )

    store.globalTaskBoardOrchestratorStatus = status
    store.globalPolicyCanvasWorkspace = workspace
    store.contentUI.dashboard.connectionState = .online
    store.contentUI.dashboard.taskBoardOrchestratorStatus = status
    store.contentUI.dashboard.policyCanvasWorkspace = workspace
    return store
  }

  private static let presentation = TaskBoardAutomationPresentation(
    statePills: [],
    queueLanes: [],
    activeRunRows: [],
    timingRows: [],
    revisionRows: [],
    issueRows: [],
    historyRuns: [],
    detail: nil,
    metricRows: [],
    cancelTargets: [],
    cancelTargetsTruncated: false,
    controlAvailability: TaskBoardAutomationControlAvailability(
      controlBlockedReason: nil,
      stopBlockedReason: nil,
      forceCancelBlockedReason: nil,
      isSnapshotStale: false
    ),
    isDegraded: false
  )
}

@MainActor
public enum TaskBoardAutomationControlsPreviewRenderer {
  public static func dump(toDirectory directory: String) -> Bool {
    render(name: "automation-controls-mixed", mode: .mixed, directory: directory)
      && render(
        name: "automation-controls-kill-switch-engaged",
        mode: .killSwitchEngaged,
        directory: directory
      )
  }

  private static func render(
    name: String,
    mode: TaskBoardAutomationControlsPreview.Mode,
    directory: String
  ) -> Bool {
    let content = TaskBoardAutomationControlsPreview(mode: mode)
      .harnessPreviewSceneAppearance()
      .environment(\.controlActiveState, .key)
    let view = NSHostingView(rootView: content)
    view.appearance = NSAppearance(named: .darkAqua)
    let contentSize = NSSize(width: 620, height: 350)
    view.setFrameSize(contentSize)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.appearance = NSAppearance(named: .darkAqua)
    window.title = "Task Board"
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.contentView = view

    NSApplication.shared.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    window.orderFrontRegardless()
    window.makeMain()
    window.makeKey()
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    window.makeFirstResponder(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    guard NSApplication.shared.isActive else {
      FileHandle.standardError.write(Data("focused preview app is inactive\n".utf8))
      window.close()
      return false
    }
    guard window.isKeyWindow else {
      FileHandle.standardError.write(Data("focused preview window is not key\n".utf8))
      window.close()
      return false
    }
    guard let snapshotView = window.contentView?.superview else {
      window.close()
      return false
    }
    snapshotView.layoutSubtreeIfNeeded()
    snapshotView.displayIfNeeded()
    defer {
      window.close()
    }
    return captureWindow(
      window,
      fallbackView: snapshotView,
      name: name,
      directory: directory
    )
  }

  private static func captureWindow(
    _ window: NSWindow,
    fallbackView: NSView,
    name: String,
    directory: String
  ) -> Bool {
    guard ProcessInfo.processInfo.environment["HARNESS_MONITOR_FOCUSED_PREVIEW_CAPTURE"] == "1"
    else {
      return captureView(fallbackView, name: name, directory: directory)
    }

    let request = URL(fileURLWithPath: directory)
      .appendingPathComponent(".capture-request-\(name)")
    let acknowledgement = URL(fileURLWithPath: directory)
      .appendingPathComponent(".capture-complete-\(name)")
    do {
      try Data("\(window.windowNumber)\n".utf8).write(to: request, options: .atomic)
    } catch {
      return false
    }

    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: acknowledgement.path), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    let destination = URL(fileURLWithPath: directory)
      .appendingPathComponent(name)
      .appendingPathExtension("png")
    guard
      FileManager.default.fileExists(atPath: acknowledgement.path),
      let attributes = try? FileManager.default.attributesOfItem(
        atPath: destination.path
      ),
      let size = attributes[.size] as? NSNumber
    else {
      return false
    }
    return size.intValue > 0
  }

  private static func captureView(
    _ view: NSView,
    name: String,
    directory: String
  ) -> Bool {
    let destination = URL(fileURLWithPath: directory)
      .appendingPathComponent(name)
      .appendingPathExtension("png")

    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      return false
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return false
    }

    do {
      try data.write(to: destination, options: .atomic)
      return true
    } catch {
      return false
    }
  }
}
