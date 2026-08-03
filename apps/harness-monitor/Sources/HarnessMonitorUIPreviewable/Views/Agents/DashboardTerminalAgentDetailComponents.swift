import HarnessMonitorKit
import SwiftUI

struct DashboardTerminalStatusCard: View {
  let detail: DashboardTerminalAgentDetail

  var body: some View {
    DashboardAcpSection(title: "Runtime and continuity") {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
        fact("Status", detail.snapshot?.status.title ?? "Unavailable")
        fact("Continuity", detail.continuity.title)
        fact("Evidence", detail.continuity.detail)
        fact("Runtime", runtimeTitle)
        fact("Terminal size", terminalSize)
        fact("Exit code", exitCode)
        fact("Signal", detail.snapshot?.signal ?? "None")
      }
    }
  }

  private var runtimeTitle: String {
    guard let rawValue = detail.snapshot?.runtime else { return "Unavailable" }
    return AgentTuiRuntime(rawValue: rawValue)?.title ?? rawValue
  }

  private var terminalSize: String {
    guard let size = detail.snapshot?.size else { return "Unavailable" }
    return "\(size.cols) × \(size.rows)"
  }

  private var exitCode: String {
    guard let code = detail.snapshot?.exitCode else { return "None" }
    return String(code)
  }

  private func fact(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
      Text(value.withoutTrailingPeriod)
        .textSelection(.enabled)
        .gridColumnAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scaledFont(.callout)
  }
}

struct DashboardTerminalViewport: View {
  let snapshot: AgentTuiSnapshot
  let onResize: @MainActor (AgentTuiSize) async -> Bool
  @Environment(\.fontScale)
  private var fontScale
  @State private var visibleRows: [AgentTuiScreenSnapshot.VisibleRow] = []
  @State private var viewportSize = CGSize.zero
  @State private var resizeCoordinator = DashboardTerminalResizeCoordinator()

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView([.horizontal, .vertical]) {
        AgentTuiTerminalOutputView(
          visibleRows: visibleRows,
          terminalSize: snapshot.size,
          wrapLines: false,
          fontScale: fontScale
        )
        .scaledFont(.caption.monospaced())
        .environment(\.colorScheme, .dark)
        .padding(12)
        .id("terminal-output")
      }
      .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
      .frame(minHeight: 260, idealHeight: 320, maxHeight: 360)
      .onGeometryChange(for: CGSize.self) { geometry in
        geometry.size
      } action: { newSize in
        guard viewportSize != newSize else { return }
        viewportSize = newSize
      }
      .task(id: resizeContext) {
        guard snapshot.status.isActive else { return }
        try? await Task.sleep(for: TerminalViewportSizing.debounce)
        guard !Task.isCancelled else { return }
        guard let target = resizeTarget else { return }
        await resizeCoordinator.request(target: target, operation: onResize)
      }
      .task(id: snapshot.screen.text) {
        visibleRows = snapshot.screen.visibleRows(maxRows: 200)
        proxy.scrollTo("terminal-output", anchor: .bottomTrailing)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(snapshot.screen.text)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalOutput)
    }
  }

  private var resizeContext: DashboardTerminalResizeContext {
    DashboardTerminalResizeContext(
      viewportSize: viewportSize,
      fontScale: fontScale,
      serverRows: snapshot.size.rows,
      serverCols: snapshot.size.cols,
      isActive: snapshot.status.isActive
    )
  }

  private var resizeTarget: AgentTuiSize? {
    guard
      let measured = TerminalViewportSizing.terminalSize(
        for: viewportSize,
        fontScale: fontScale
      )
    else { return nil }
    let stabilized = TerminalViewportSizing.stabilizedAutomaticSize(
      measured: measured,
      baseline: snapshot.size
    )
    return stabilized == snapshot.size ? nil : stabilized
  }
}

private struct DashboardTerminalResizeContext: Hashable {
  let viewportSize: CGSize
  let fontScale: CGFloat
  let serverRows: Int
  let serverCols: Int
  let isActive: Bool
}

private actor DashboardTerminalResizeCoordinator {
  private var latestTarget: AgentTuiSize?
  private var isRunning = false

  func request(
    target: AgentTuiSize,
    operation: @escaping @MainActor @Sendable (AgentTuiSize) async -> Bool
  ) {
    latestTarget = target
    guard !isRunning else { return }
    isRunning = true
    Task { await drain(operation: operation) }
  }

  private func drain(
    operation: @escaping @MainActor @Sendable (AgentTuiSize) async -> Bool
  ) async {
    while let target = latestTarget {
      latestTarget = nil
      let succeeded = await operation(target)
      if !succeeded, latestTarget == nil {
        try? await Task.sleep(for: .seconds(1))
        if latestTarget == nil { _ = await operation(target) }
      }
    }
    isRunning = false
  }
}

struct DashboardTerminalComposer: View {
  @Bindable var state: DashboardTerminalAgentDetailState
  let isTerminalActive: Bool
  let onSend: () -> Void
  let onControl: (AgentTuiInput) -> Void

  var body: some View {
    DashboardAcpSection(title: "Terminal input") {
      TextField("Type terminal input", text: $state.input)
        .textFieldStyle(.roundedBorder)
        .onSubmit(onSend)
        .disabled(!isEnabled)
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalInputField)
      DashboardTerminalControlBar(
        isEnabled: isEnabled,
        canSend: canSend,
        onSend: onSend,
        onControl: onControl
      )
    }
  }

  private var canSend: Bool {
    isEnabled && !state.input.isEmpty
  }

  private var isEnabled: Bool {
    isTerminalActive && state.activeAction == nil
  }

}

private struct DashboardTerminalControlBar: View {
  let isEnabled: Bool
  let canSend: Bool
  let onSend: () -> Void
  let onControl: (AgentTuiInput) -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        commonControls
        Spacer()
        sendButton
      }
      VStack(alignment: .trailing, spacing: 8) {
        HStack(spacing: 8) {
          controlButton("Enter", input: .key(.enter))
          controlButton("Ctrl-C", input: .control("c"))
            .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalControlCButton)
          compactKeyMenu
          Spacer()
        }
        sendButton
      }
    }
  }

  @ViewBuilder private var commonControls: some View {
    controlButton("Enter", input: .key(.enter))
    controlButton("Esc", input: .key(.escape))
    controlButton("Tab", input: .key(.tab))
    controlButton("Ctrl-C", input: .control("c"))
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalControlCButton)
    moreKeyMenu
  }

  private var compactKeyMenu: some View {
    Menu("Keys") {
      controlButton("Esc", input: .key(.escape))
      controlButton("Tab", input: .key(.tab))
      moreKeyItems
    }
    .disabled(!isEnabled)
  }

  private var moreKeyMenu: some View {
    Menu("More keys") { moreKeyItems }
      .disabled(!isEnabled)
  }

  @ViewBuilder private var moreKeyItems: some View {
    controlButton("Backspace", input: .key(.backspace))
    Divider()
    controlButton("Up", input: .key(.arrowUp))
    controlButton("Down", input: .key(.arrowDown))
    controlButton("Left", input: .key(.arrowLeft))
    controlButton("Right", input: .key(.arrowRight))
  }

  private var sendButton: some View {
    Button("Send") { onSend() }
      .buttonStyle(.borderedProminent)
      .disabled(!canSend)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalSendButton)
  }

  private func controlButton(_ title: String, input: AgentTuiInput) -> some View {
    Button(title) { onControl(input) }
      .disabled(!isEnabled)
  }
}

struct DashboardTerminalRuntimeFacts: View {
  let snapshot: AgentTuiSnapshot

  var body: some View {
    DashboardAcpSection(title: "Runtime facts") {
      fact("Managed agent ID", snapshot.tuiId)
      fact("Terminal agent ID", snapshot.agentId)
      fact("Process arguments", snapshot.argv.joined(separator: " "))
      fact("Workspace path", snapshot.projectDir)
      fact("Transcript", snapshot.transcriptPath)
      if let error = snapshot.error { fact("Failure", error) }
      fact("Created", snapshot.createdAt)
      fact("Updated", snapshot.updatedAt)
    }
  }

  private func fact(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).scaledFont(.caption.weight(.medium)).foregroundStyle(.secondary)
      Text(value.isEmpty ? "—" : value.withoutTrailingPeriod).textSelection(.enabled)
    }
  }
}
