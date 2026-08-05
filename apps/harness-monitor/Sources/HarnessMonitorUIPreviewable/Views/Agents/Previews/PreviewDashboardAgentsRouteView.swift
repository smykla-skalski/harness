import AppKit
import HarnessMonitorKit
import SwiftUI

public enum DashboardAgentsPreviewRenderer {
  @MainActor
  public static func dump(toDirectory directory: String) -> Bool {
    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
      )
    } catch {
      return false
    }

    let defaultIndex = HarnessMonitorTextSize.defaultIndex
    let largestIndex = HarnessMonitorTextSize.scales.count - 1
    return render(
      name: "agents-live",
      state: DashboardAgentsPreviewFixtures.liveState,
      textSizeIndex: defaultIndex,
      directory: directory
    )
      && render(
        name: "agents-first-run",
        state: DashboardAgentsPreviewFixtures.firstRunState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-live-largest-text",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: largestIndex,
        directory: directory
      )
      && render(
        name: "agents-loading",
        state: DashboardAgentsPreviewFixtures.loadingState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-empty",
        state: DashboardAgentsPreviewFixtures.emptyState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-stale-cache",
        state: DashboardAgentsPreviewFixtures.cachedState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-offline",
        state: DashboardAgentsPreviewFixtures.offlineState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && render(
        name: "agents-request-failure",
        state: DashboardAgentsPreviewFixtures.failureState,
        textSizeIndex: defaultIndex,
        directory: directory
      )
      && renderAcpStates(
        defaultIndex: defaultIndex,
        largestIndex: largestIndex,
        directory: directory
      )
      && renderCodexStates(
        defaultIndex: defaultIndex,
        largestIndex: largestIndex,
        directory: directory
      )
      && renderTerminalStates(
        defaultIndex: defaultIndex,
        largestIndex: largestIndex,
        directory: directory
      )
      && renderDecisionStates(
        defaultIndex: defaultIndex,
        largestIndex: largestIndex,
        directory: directory
      )
      && renderHeaderStates(textSizeIndex: defaultIndex, directory: directory)
  }

  @MainActor
  private static func renderDecisionStates(
    defaultIndex: Int,
    largestIndex: Int,
    directory: String
  ) -> Bool {
    let bucketSession = DashboardAgentsPreviewFixtures.decisionBucketSession
    let bucketWorkspaceID = DashboardAgentWorkspaceIdentity(
      projectID: bucketSession.projectId,
      checkoutID: bucketSession.checkoutId
    )
    let bucketSelection = DashboardAgentsSelection.workspaceDecisions(bucketWorkspaceID)
    return render(
      name: "agents-decisions-list",
      state: DashboardAgentsPreviewFixtures.liveState,
      textSizeIndex: defaultIndex,
      directory: directory,
      selectedIdentity: DashboardAgentsPreviewFixtures.acpAgent.identity,
      decisions: DashboardAgentsPreviewFixtures.previewDecisions,
      bucketSession: DashboardAgentsPreviewFixtures.decisionBucketSession,
      initialAcpDetail: DashboardAgentsPreviewFixtures.managedAcpDetail
    )
      && render(
        name: "agents-decisions-terminal",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.liveAgents[0].identity,
        decisions: DashboardAgentsPreviewFixtures.previewDecisions,
        bucketSession: DashboardAgentsPreviewFixtures.decisionBucketSession,
        initialTerminalDetail: DashboardAgentsPreviewFixtures.managedTerminalDetail
      )
      && render(
        name: "agents-decisions-workspace-bucket",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectionRawValue: bucketSelection.rawValue,
        decisions: DashboardAgentsPreviewFixtures.previewDecisions,
        bucketSession: DashboardAgentsPreviewFixtures.decisionBucketSession
      )
      && render(
        name: "agents-decisions-bucket-only",
        state: DashboardAgentsPreviewFixtures.emptyState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectionRawValue: bucketSelection.rawValue,
        decisions: DashboardAgentsPreviewFixtures.previewDecisions.filter {
          $0.id == "unassigned-task:mesh-4821"
        },
        bucketSession: DashboardAgentsPreviewFixtures.decisionBucketSession
      )
      && render(
        name: "agents-decisions-global",
        state: DashboardAgentsPreviewFixtures.emptyState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectionRawValue: DashboardAgentsSelection.globalDecisions.rawValue,
        decisions: DashboardAgentsPreviewFixtures.previewDecisions.filter {
          $0.id == "quarantine:observer-issue-escalation"
        }
      )
      && render(
        name: "agents-decisions-largest-text",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: largestIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.liveAgents[1].identity,
        decisions: DashboardAgentsPreviewFixtures.previewDecisions,
        bucketSession: DashboardAgentsPreviewFixtures.decisionBucketSession,
        initialCodexDetail: DashboardAgentsPreviewFixtures.managedCodexDetail
      )
  }

}

extension DashboardAgentsPreviewRenderer {
  @MainActor
  private static func renderAcpStates(
    defaultIndex: Int,
    largestIndex: Int,
    directory: String
  ) -> Bool {
    render(
      name: "agents-acp-management",
      state: DashboardAgentsPreviewFixtures.liveState,
      textSizeIndex: defaultIndex,
      directory: directory,
      selectedIdentity: DashboardAgentsPreviewFixtures.acpAgent.identity,
      initialAcpDetail: DashboardAgentsPreviewFixtures.managedAcpDetail
    )
      && render(
        name: "agents-acp-largest-text",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: largestIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.acpAgent.identity,
        initialAcpDetail: DashboardAgentsPreviewFixtures.managedAcpDetail
      )
      && render(
        name: "agents-acp-unavailable",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.acpAgent.identity,
        initialAcpDetail: DashboardAgentsPreviewFixtures.unavailableAcpDetail
      )
      && render(
        name: "agents-acp-stopped",
        state: DashboardAgentsPreviewFixtures.stoppedAcpState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.stoppedAcpAgent.identity,
        initialAcpDetail: DashboardAgentsPreviewFixtures.stoppedAcpDetail
      )
      && renderAcpCreateSheet(textSizeIndex: defaultIndex, directory: directory)
  }

  @MainActor
  private static func renderCodexStates(
    defaultIndex: Int,
    largestIndex: Int,
    directory: String
  ) -> Bool {
    render(
      name: "agents-codex-management",
      state: DashboardAgentsPreviewFixtures.liveState,
      textSizeIndex: defaultIndex,
      directory: directory,
      selectedIdentity: DashboardAgentsPreviewFixtures.codexAgent.identity,
      initialCodexDetail: DashboardAgentsPreviewFixtures.managedCodexDetail
    )
      && render(
        name: "agents-codex-largest-text",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: largestIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.codexAgent.identity,
        initialCodexDetail: DashboardAgentsPreviewFixtures.managedCodexDetail
      )
      && render(
        name: "agents-codex-unavailable",
        state: DashboardAgentsPreviewFixtures.liveState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.codexAgent.identity,
        initialCodexDetail: DashboardAgentsPreviewFixtures.unavailableCodexDetail
      )
      && render(
        name: "agents-codex-stopped",
        state: DashboardAgentsPreviewFixtures.stoppedCodexState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.stoppedCodexAgent.identity,
        initialCodexDetail: DashboardAgentsPreviewFixtures.stoppedCodexDetail
      )
      && render(
        name: "agents-codex-failed",
        state: DashboardAgentsPreviewFixtures.failedCodexState,
        textSizeIndex: defaultIndex,
        directory: directory,
        selectedIdentity: DashboardAgentsPreviewFixtures.failedCodexAgent.identity,
        initialCodexDetail: DashboardAgentsPreviewFixtures.failedCodexDetail
      )
      && renderCodexCreateSheet(textSizeIndex: defaultIndex, directory: directory)
  }

  @MainActor
  static func render(
    name: String,
    state: DashboardAgentBrowserViewState,
    textSizeIndex: Int,
    directory: String,
    selectedIdentity: DashboardAgentIdentity? = nil,
    selectionRawValue: String? = nil,
    decisions: [Decision] = [],
    bucketSession: SessionSummary? = nil,
    initialTerminalDetail: DashboardTerminalAgentDetail? = nil,
    initialAcpDetail: DashboardAcpAgentDetail? = nil,
    initialCodexDetail: DashboardCodexAgentDetail? = nil
  ) -> Bool {
    let size = NSSize(width: 1040, height: 700)
    let hosted = DashboardAgentsPreviewSurface(
      state: state,
      selectedIdentity: selectedIdentity,
      selectionRawValue: selectionRawValue,
      decisions: decisions,
      bucketSession: bucketSession,
      initialTerminalDetail: initialTerminalDetail,
      initialAcpDetail: initialAcpDetail,
      initialCodexDetail: initialCodexDetail
    )
    .frame(width: size.width, height: size.height)
    .background(Color(nsColor: .windowBackgroundColor))
    .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: hosted)
    view.appearance = NSAppearance(named: .darkAqua)
    view.setFrameSize(size)
    let window = NSWindow(
      contentRect: view.bounds,
      styleMask: .borderless,
      backing: .buffered,
      defer: false,
      screen: NSScreen.main
    )
    window.contentView = view
    for _ in 0..<3 {
      view.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    view.layoutSubtreeIfNeeded()

    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      return false
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return false
    }
    do {
      try data.write(
        to: URL(fileURLWithPath: directory)
          .appendingPathComponent(name)
          .appendingPathExtension("png"),
        options: .atomic
      )
      return true
    } catch {
      return false
    }
  }

  @MainActor
  private static func renderAcpCreateSheet(textSizeIndex: Int, directory: String) -> Bool {
    let size = NSSize(width: 1040, height: 700)
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)
    let hosted = ZStack {
      Color(nsColor: .windowBackgroundColor)
      DashboardAcpAgentCreateSheet(
        store: store,
        sessions: [PreviewFixtures.summary],
        initialDescriptors: [DashboardAgentsPreviewFixtures.acpDescriptor],
        initialProbes: [DashboardAgentsPreviewFixtures.acpProbe],
        onCreated: { _, _ in }
      )
      .frame(width: 680, height: 640)
      .background(.background, in: RoundedRectangle(cornerRadius: 14))
      .shadow(radius: 20)
    }
    .frame(width: size.width, height: size.height)
    .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: hosted)
    view.appearance = NSAppearance(named: .darkAqua)
    view.setFrameSize(size)
    view.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return false
    }
    do {
      try data.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("agents-acp-create.png"),
        options: .atomic
      )
      return true
    } catch {
      return false
    }
  }

  @MainActor
  private static func renderCodexCreateSheet(textSizeIndex: Int, directory: String) -> Bool {
    renderSheet(
      name: "agents-codex-create",
      textSizeIndex: textSizeIndex,
      directory: directory
    ) {
      DashboardCodexAgentCreateSheet(
        store: HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded),
        sessions: [PreviewFixtures.summary],
        initialCatalogs: [DashboardAgentsPreviewFixtures.codexCatalog],
        onCreated: { _, _ in }
      )
      .frame(width: 680, height: 660)
    }
  }

  @MainActor
  static func renderSheet<Content: View>(
    name: String,
    textSizeIndex: Int,
    directory: String,
    @ViewBuilder content: () -> Content
  ) -> Bool {
    let size = NSSize(width: 1040, height: 700)
    let hosted = ZStack {
      Color(nsColor: .windowBackgroundColor)
      content()
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 20)
    }
    .frame(width: size.width, height: size.height)
    .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: hosted)
    view.appearance = NSAppearance(named: .darkAqua)
    view.setFrameSize(size)
    view.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return false
    }
    do {
      try data.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"),
        options: .atomic
      )
      return true
    } catch {
      return false
    }
  }
}
