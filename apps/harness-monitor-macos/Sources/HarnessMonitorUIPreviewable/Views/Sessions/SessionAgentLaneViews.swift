import HarnessMonitorKit
import SwiftUI

struct SessionAgentTuiViewport: View {
  let store: HarnessMonitorStore
  let agentID: String
  let tui: AgentTuiSnapshot?
  let metrics: SessionAgentDetailSectionMetrics
  let latestOutput: String
  @Environment(\.fontScale)
  private var fontScale

  @State private var visibleRows: [AgentTuiScreenSnapshot.VisibleRow] = []
  @State private var lastScrollAt = Date.distantPast
  @State private var resizeState = SessionAgentTuiViewportResizeState()

  private static let scrollThrottleInterval: TimeInterval = 1.0 / 60.0

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: metrics.terminalRowSpacing) {
          if visibleRows.isEmpty {
            Text(tui == nil ? "No terminal attached" : "No terminal output")
              .scaledFont(.caption.monospaced())
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            ForEach(visibleRows) { row in
              Text(row.text.isEmpty ? " " : row.text)
                .scaledFont(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(row.id)
            }
          }
        }
        .padding(metrics.terminalPadding)
      }
      .background(
        .quaternary.opacity(0.4),
        in: RoundedRectangle(cornerRadius: metrics.terminalCornerRadius)
      )
      .scrollBounceBehavior(.always, axes: .vertical)
      .frame(
        minHeight: TerminalViewportSizing.minimumViewportHeight,
        idealHeight: TerminalViewportSizing.idealViewportHeight,
        maxHeight: (tui?.status.isActive == true)
          ? .infinity
          : TerminalViewportSizing.idealViewportHeight
      )
      .onGeometryChange(for: CGSize.self) { proxy in
        proxy.size
      } action: { newSize in
        Task { @MainActor in
          await syncTerminalSize(viewportSize: newSize)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(latestOutput))
      .accessibilityIdentifier(tuiViewportIdentifier)
      .task(id: agentID) {
        visibleRows = tui?.screen.visibleRows(maxRows: 160) ?? []
      }
      .onDisappear {
        resizeState.cancelPending()
      }
      // Debounce TUI bursts via .task(id:); each text change cancels the
      // in-flight wait so byte-by-byte emissions coalesce into batches.
      // Scroll throttle is preserved unchanged.
      .task(id: tui?.screen.text ?? "") {
        try? await Task.sleep(for: .milliseconds(30))
        guard !Task.isCancelled else { return }
        let nextRows = tui?.screen.visibleRows(maxRows: 160) ?? []
        visibleRows = nextRows
        let now = Date.now
        guard now.timeIntervalSince(lastScrollAt) >= Self.scrollThrottleInterval else { return }
        lastScrollAt = now
        if let last = nextRows.last {
          proxy.scrollTo(last.id, anchor: .bottom)
        }
      }
    }
  }

  private var tuiViewportIdentifier: String {
    HarnessMonitorAccessibility.sessionAgentTuiViewport(agentID)
  }

  @MainActor
  private func syncTerminalSize(viewportSize: CGSize) async {
    guard let tui, tui.status.isActive else { return }
    guard resizeState.recordViewportPoints(viewportSize) else { return }
    guard
      let measured = TerminalViewportSizing.terminalSize(
        for: viewportSize,
        fontScale: fontScale
      )
    else {
      resizeState.clearMeasuredTerminalSize()
      return
    }
    resizeState.recordMeasuredTerminalSize(measured)
    let baseline = TerminalViewportSizing.automaticResizeBaseline(
      serverSize: tui.size,
      pendingTarget: resizeState.pendingTarget,
      expectedSize: resizeState.expectedSize
    )
    let stabilized = TerminalViewportSizing.stabilizedAutomaticSize(
      measured: measured,
      baseline: baseline
    )
    guard stabilized != tui.size, stabilized != resizeState.pendingTarget else { return }
    resizeState.pendingTarget = stabilized
    resizeState.expectedSize = stabilized
    resizeState.cancelPending()
    let tuiID = tui.tuiId
    let store = store
    resizeState.resizeTask = Task { @MainActor in
      try? await Task.sleep(for: TerminalViewportSizing.debounce)
      guard !Task.isCancelled else { return }
      _ = await store.resizeAgentTui(
        tuiID: tuiID,
        rows: stabilized.rows,
        cols: stabilized.cols,
        feedback: .silent
      )
      if resizeState.pendingTarget == stabilized {
        resizeState.pendingTarget = nil
      }
    }
  }
}

@MainActor
@Observable
final class SessionAgentTuiViewportResizeState {
  var lastMeasuredPoints: CGSize?
  var lastMeasuredTerminalSize: AgentTuiSize?
  var expectedSize: AgentTuiSize?
  var pendingTarget: AgentTuiSize?
  @ObservationIgnored nonisolated(unsafe) var resizeTask: Task<Void, Never>?

  deinit {
    resizeTask?.cancel()
  }

  func recordViewportPoints(_ size: CGSize) -> Bool {
    guard lastMeasuredPoints != size else { return false }
    lastMeasuredPoints = size
    return true
  }

  func clearMeasuredTerminalSize() {
    lastMeasuredTerminalSize = nil
  }

  func recordMeasuredTerminalSize(_ size: AgentTuiSize) {
    guard lastMeasuredTerminalSize != size else { return }
    lastMeasuredTerminalSize = size
  }

  func cancelPending() {
    resizeTask?.cancel()
    resizeTask = nil
  }
}

struct SessionAgentListSection: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let sessionStatus: SessionStatus
  let agents: [AgentRegistration]
  let tasks: [WorkItem]
  let isSessionReadOnly: Bool
  let openAgent: (String) -> Void
  let tuiStatusByAgent: [String: AgentTuiStatus]
  @Environment(\.openWindow)
  private var openWindow

  private var agentStateMarkerText: String {
    let agentIDs = agents.map(\.agentId).joined(separator: ",")
    let runtimes = Array(Set(agents.map(\.runtime))).sorted().joined(separator: ",")
    return "agentCount=\(agents.count), agentIDs=\(agentIDs), runtimes=\(runtimes)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.sessionAgentListState,
        text: agentStateMarkerText
      )
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.itemSpacing) {
        Text("Agents")
          .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer()
        newAgentButton
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityTestProbe(
        HarnessMonitorAccessibility.sessionAgentListHeader,
        label: "Agents"
      )
      .accessibilityFrameMarker(HarnessMonitorAccessibility.sessionAgentListHeaderFrame)
      if agents.isEmpty {
        if sessionStatus == .awaitingLeader {
          HStack(spacing: 0) {
            Text("No agents yet. Join a leader to activate this session.")
              .scaledFont(SessionCockpitEmptyStateRow.baseFont)
              .foregroundStyle(.secondary)
            Spacer(minLength: 0)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text("No agents yet. Join a leader to activate this session."))
          .accessibilityIdentifier(
            SessionCockpitEmptyStateRow.Section.agents.accessibilityIdentifier
          )
        } else {
          SessionCockpitEmptyStateRow(section: .agents)
        }
      } else {
        LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
          ForEach(agents) { agent in
            SessionAgentSummaryCard(
              store: store,
              sessionID: sessionID,
              agent: agent,
              queuedTasks: tasks.queued(for: agent.agentId),
              isSessionReadOnly: isSessionReadOnly,
              openAgent: openAgent,
              tuiStatus: tuiStatusByAgent[agent.agentId]
            )
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var newAgentButton: some View {
    HarnessMonitorActionButton(
      title: "New Agent",
      variant: .bordered,
      accessibilityIdentifier: HarnessMonitorAccessibility.sessionAgentCreateOpenButton
    ) {
      openNewAgent()
    }
    .help("Open workspace and create a new agent")
  }

  private func openNewAgent() {
    store.requestSessionRouteCreate(.agent, sessionID: sessionID)
    openWindow.openHarnessSessionWindow(sessionID: sessionID)
  }
}
