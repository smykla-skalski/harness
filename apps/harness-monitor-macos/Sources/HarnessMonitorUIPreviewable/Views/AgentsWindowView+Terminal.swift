import AppKit
import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  static func pendingUserPrompt(
    for tui: AgentTuiSnapshot,
    session: SessionDetail?
  ) -> AgentPendingUserPrompt? {
    guard
      let prompt = session?.agentActivity.first(where: { $0.agentId == tui.agentId })?.pendingUserPrompt,
      !prompt.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }

    return prompt
  }

  func terminalHeader(_ tui: AgentTuiSnapshot) -> some View {
    @Bindable var viewModel = viewModel
    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(resolvedTitle(for: tui))
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
      HStack(alignment: .firstTextBaseline) {
        Text("\(tui.status.title) • \(tui.size.rows)x\(tui.size.cols)")
          .scaledFont(.caption.monospacedDigit())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer()
        Toggle("Wrap lines", isOn: $viewModel.wrapLines)
          .toggleStyle(ClickableSwitchStyle())
          .scaledFont(.caption)
          .controlSize(.mini)
          .keyboardShortcut("l", modifiers: [.command])
          .accessibilityHint("Wraps long terminal lines to fit the viewport")
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiWrapToggle)
      }
    }
  }
  func terminalViewport(_ tui: AgentTuiSnapshot) -> some View {
    let visibleRows = tui.screen.visibleRows()
    return ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 6)
        .fill(.quaternary)

      ScrollView(viewModel.wrapLines ? .vertical : [.horizontal, .vertical]) {
        AgentTuiTerminalOutputView(
          visibleRows: visibleRows,
          terminalSize: tui.size,
          wrapLines: viewModel.wrapLines,
          fontScale: fontScale
        )
      }
      .scaledFont(.system(.body, design: .monospaced))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(HarnessMonitorTheme.spacingMD)
    }
    .frame(
      maxWidth: .infinity,
      minHeight: TerminalViewportSizing.minimumViewportHeight,
      idealHeight: TerminalViewportSizing.idealViewportHeight,
      maxHeight: tui.status.isActive ? .infinity : TerminalViewportSizing.idealViewportHeight
    )
    .onGeometryChange(for: CGSize.self) { proxy in
      proxy.size
    } action: { viewportSize in
      updateViewportGeometry(viewportSize, for: tui)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiViewport)
  }
  func terminalError(_ error: String) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Error")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(error)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.danger)
        .textSelection(.enabled)
    }
  }

  @ViewBuilder
  func terminalOutcome(_ tui: AgentTuiSnapshot) -> some View {
    if !tui.status.isActive {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("Exit")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        if let exitCode = tui.exitCode {
          Text("Exit code \(exitCode)")
            .scaledFont(.subheadline)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        if let signal = tui.signal, !signal.isEmpty {
          Text("Signal \(signal)")
            .scaledFont(.subheadline)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
    }
  }
  func terminalInputControls(_ tui: AgentTuiSnapshot) -> some View {
    @Bindable var viewModel = viewModel
    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Input")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      HStack(alignment: .center, spacing: HarnessMonitorTheme.sectionSpacing) {
        HarnessMonitorSegmentedPicker(
          title: "Input mode",
          selection: $viewModel.inputMode,
          accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiInputModePicker
        ) {
          ForEach(AgentTuiInputMode.allCases) { mode in
            Text(mode.title)
              .tag(mode)
              .accessibilityIdentifier(
                HarnessMonitorAccessibility.segmentedOption(
                  HarnessMonitorAccessibility.agentTuiInputModePicker,
                  option: mode.title
                )
              )
          }
        }
        Toggle("Send Enter after input", isOn: $submitSendsEnter)
          .toggleStyle(ClickableSwitchStyle())
          .scaledFont(.caption)
          .controlSize(.mini)
          .accessibilityHint("Sends an Enter key after the typed or pasted input")
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSubmitWithEnterToggle)
      }
      HStack(alignment: .top, spacing: HarnessMonitorTheme.sectionSpacing) {
        multilineEditor(
          placeholder: "Text to send to the TUI",
          text: $viewModel.inputText,
          field: .input,
          minHeight: 72,
          accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiInputField,
          onCommandReturn: { sendInput(to: tui) }
        )
        HarnessMonitorActionButton(
          title: "Send",
          variant: .bordered,
          accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiSendButton
        ) {
          sendInput(to: tui)
        }
        .disabled(!canSend)
        .accessibilityTestProbe(
          HarnessMonitorAccessibility.agentTuiSendButton,
          label: "Send"
        )
      }
    }
  }
  func terminalPendingUserPrompt(_ prompt: AgentPendingUserPrompt) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label("User input required", systemImage: "questionmark.bubble.fill")
        .scaledFont(.headline)
        .foregroundStyle(.orange)
      Text(prompt.message)
        .scaledFont(.subheadline)
        .textSelection(.enabled)
      Text("This terminal agent is paused until you respond with the controls below.")
        .scaledFont(.footnote)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(HarnessMonitorTheme.spacingMD)
    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiPendingUserPrompt)
  }
  func terminalKeyControls(_ tui: AgentTuiSnapshot) -> some View {
    @Bindable var keySequenceBuffer = viewModel.keySequenceBuffer
    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Text("Keys")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        if let pendingHint = keySequenceBuffer.pendingHint {
          Text("Pending \(pendingHint)")
            .lineLimit(1)
            .scaledFont(.footnote.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiKeyQueueHint)
        }
      }
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.itemSpacing,
        lineSpacing: HarnessMonitorTheme.itemSpacing
      ) {
        ForEach(commonKeys) { key in
          Button {
            sendKey(key, to: tui)
          } label: {
            Text(key.glyph)
              .lineLimit(1)
              .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
              .frame(minWidth: 44)
          }
          .harnessActionButtonStyle(variant: .bordered, tint: nil)
          .controlSize(HarnessMonitorControlMetrics.compactControlSize)
          .disabled(!tui.status.isActive || viewModel.isSubmitting)
          .accessibilityLabel(key.title)
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiKeyButton(key.rawValue))
          .help(key.title)
        }
        Button {
          sendControl("c", to: tui)
        } label: {
          Text("⌃C")
            .lineLimit(1)
            .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
            .frame(minWidth: 44)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: nil)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .disabled(!tui.status.isActive || viewModel.isSubmitting)
        .accessibilityLabel("Control-C")
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiKeyButton("ctrl-c"))
        .help("Control-C")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  func terminalResizeControls() -> some View {
    @Bindable var viewModel = viewModel
    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Viewport")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text("Drag the divider below the output or resize the window to sync the live TUI.")
        .scaledFont(.footnote)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: HarnessMonitorTheme.sectionSpacing) {
        Stepper(
          "Rows \(viewModel.rows)",
          value: $viewModel.rows,
          in: TerminalViewportSizing.rowRange
        )
        Stepper(
          "Cols \(viewModel.cols)",
          value: $viewModel.cols,
          in: TerminalViewportSizing.colRange,
          step: 10
        )
        Spacer()
        if let selectedSessionTui {
          HarnessMonitorActionButton(
            title: "Apply Size",
            variant: .bordered,
            accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiResizeButton
          ) {
            resizeTui(selectedSessionTui)
          }
          .disabled(!canResize)
          .accessibilityTestProbe(
            HarnessMonitorAccessibility.agentTuiResizeButton,
            label: "Apply Size"
          )
        }
      }
    }
  }
  func multilineEditor(
    placeholder: String,
    text: Binding<String>,
    field: Field,
    minHeight: CGFloat,
    accessibilityIdentifier: String,
    onCommandReturn: (() -> Void)? = nil
  ) -> some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))

      if text.wrappedValue.isEmpty {
        Text(placeholder)
          .scaledFont(.body)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .padding(.horizontal, HarnessMonitorTheme.spacingMD)
          .padding(.vertical, HarnessMonitorTheme.spacingSM)
          .allowsHitTesting(false)
      }

      TextEditor(text: text)
        .scaledFont(.body)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, HarnessMonitorTheme.spacingSM)
        .padding(.vertical, HarnessMonitorTheme.spacingXS)
        .focused(focusedFieldBinding, equals: field)
        .accessibilityIdentifier(accessibilityIdentifier)
        .background {
          if let onCommandReturn {
            CommandReturnKeyMonitor(
              isEnabled: focusedField == field,
              action: onCommandReturn
            )
          }
        }
    }
    .frame(minHeight: minHeight)
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
    }
    .accessibilityFrameMarker(accessibilityIdentifier)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(accessibilityIdentifier)
  }
  var agentTuiUnavailableBanner: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label(agentTuiBridgeTitle, systemImage: "exclamationmark.triangle")
        .scaledFont(.headline)
        .foregroundStyle(.orange)
      Text(agentTuiBridgeMessage)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if agentTuiBridgeState == .excluded && hostBridge.running {
        Button("Enable now") {
          Task {
            _ = await store.setHostBridgeCapability("agent-tui", enabled: true)
          }
        }
        .harnessActionButtonStyle(variant: .prominent, tint: nil)
        .disabled(store.isDaemonActionInFlight || viewModel.isSubmitting)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiEnableBridgeButton)
      }
      CopyableCommandBox(
        command: agentTuiBridgeCommand,
        accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiCopyCommandButton
      )
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRecoveryBanner)
  }
  var agentTuiBridgeState: HarnessMonitorStore.HostBridgeCapabilityState {
    store.hostBridgeCapabilityState(for: "agent-tui")
  }
  var agentTuiBridgeCommand: String {
    store.hostBridgeStartCommand(for: "agent-tui")
  }
  var hostBridge: HostBridgeManifest {
    store.daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
  }
  var agentTuiBridgeCapabilityPresent: Bool {
    hostBridge.capabilities["agent-tui"] != nil
  }
  var agentTuiBridgeTitle: String {
    switch agentTuiBridgeState {
    case .excluded:
      "Terminal agents are excluded from the host bridge"
    case .unavailable:
      "Terminal agent host bridge is not running"
    case .ready:
      "Terminal agent host bridge ready"
    }
  }
  var agentTuiBridgeMessage: String {
    switch agentTuiBridgeState {
    case .excluded:
      "The shared host bridge is running without terminal control enabled. "
        + "Enable it now or run this in a terminal:"
    case .unavailable:
      if hostBridge.running && agentTuiBridgeCapabilityPresent {
        "The shared host bridge is running, but terminal control is unavailable. "
          + "Re-enable it or run this in a terminal:"
      } else {
        "Harness Monitor runs sandboxed and needs the host bridge to start "
          + "or steer terminal-backed agents. Run this in a terminal:"
      }
    case .ready:
      ""
    }
  }
  var codexUnavailableBanner: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label(codexBridgeTitle, systemImage: "exclamationmark.triangle")
        .scaledFont(.headline)
        .foregroundStyle(.orange)
      Text(codexBridgeMessage)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if codexBridgeState == .excluded && hostBridge.running {
        Button("Enable now") {
          Task {
            _ = await store.setHostBridgeCapability("codex", enabled: true)
          }
        }
        .harnessActionButtonStyle(variant: .prominent, tint: nil)
        .disabled(store.isDaemonActionInFlight || viewModel.isSubmitting)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentsCodexEnableBridgeButton)
      }
      CopyableCommandBox(
        command: codexBridgeCommand,
        accessibilityIdentifier: HarnessMonitorAccessibility.agentsCodexCopyCommandButton
      )
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentsCodexRecoveryBanner)
  }
  var codexBridgeState: HarnessMonitorStore.HostBridgeCapabilityState {
    store.hostBridgeCapabilityState(for: "codex")
  }
  var codexBridgeCommand: String {
    store.hostBridgeStartCommand(for: "codex")
  }
  var codexBridgeCapabilityPresent: Bool {
    hostBridge.capabilities["codex"] != nil
  }
  var codexBridgeTitle: String {
    switch codexBridgeState {
    case .excluded:
      "Codex is excluded from the host bridge"
    case .unavailable:
      if hostBridge.running && codexBridgeCapabilityPresent {
        "Codex host bridge is unavailable"
      } else {
        "Codex host bridge is not running"
      }
    case .ready:
      "Codex host bridge ready"
    }
  }
  var codexBridgeMessage: String {
    switch codexBridgeState {
    case .excluded:
      "The shared host bridge is running without Codex enabled. Enable it now or run this in a terminal:"
    case .unavailable:
      if hostBridge.running && codexBridgeCapabilityPresent {
        """
        The shared host bridge is running, but the Codex capability is unavailable.
        Re-enable it or run this in a terminal:
        """
      } else {
        """
        Harness Monitor runs sandboxed and needs the host bridge to start or steer
        Codex threads. Run this in a terminal:
        """
      }
    case .ready:
      ""
    }
  }
}
