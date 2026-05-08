import HarnessMonitorKit
import SwiftUI

struct SessionAgentDetailSectionMetrics: Equatable {
  let sectionSpacing: CGFloat
  let sectionPadding: CGFloat
  let headerSpacing: CGFloat
  let terminalRowSpacing: CGFloat
  let terminalPadding: CGFloat
  let terminalCornerRadius: CGFloat
  let composerSpacing: CGFloat
  let keyStackSpacing: CGFloat
  let keyButtonWidth: CGFloat
  let controlButtonMinSize: CGFloat
  let composerMinHeight: CGFloat
  let composerMaxHeight: CGFloat

  init(fontScale: CGFloat) {
    let scale = min(max(fontScale, 0.85), 1.8)
    sectionSpacing = 12 * min(scale, 1.35)
    sectionPadding = 20 * min(scale, 1.25)
    headerSpacing = 4 * min(scale, 1.4)
    terminalRowSpacing = 2 * min(scale, 1.35)
    terminalPadding = 12 * min(scale, 1.35)
    terminalCornerRadius = 8 * min(scale, 1.2)
    composerSpacing = 8 * min(scale, 1.35)
    keyStackSpacing = 6 * min(scale, 1.35)
    keyButtonWidth = max(22, 22 * min(scale, 1.3))
    controlButtonMinSize = scale >= 1.45 ? 44 : 0
    composerMinHeight = max(46, 46 * min(scale, 1.35))
    composerMaxHeight = max(120, 120 * min(scale, 1.2))
  }
}

struct SessionAgentDetailSection: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agent: AgentRegistration
  let tui: AgentTuiSnapshot?
  @Environment(\.fontScale)
  private var fontScale
  @State private var message = ""
  @State private var lastAnnouncementAt = Date.distantPast
  @FocusState private var focusedField: Field?

  private enum Field {
    case composer
  }

  private var latestOutput: String {
    let rows = tui?.screen.visibleRows(maxRows: 1) ?? []
    return rows.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No output"
  }

  private var visibleRows: [AgentTuiScreenSnapshot.VisibleRow] {
    tui?.screen.visibleRows(maxRows: 160) ?? []
  }

  private var canSendInput: Bool {
    tui?.status.isActive == true && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var metrics: SessionAgentDetailSectionMetrics {
    SessionAgentDetailSectionMetrics(fontScale: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
      header
      tuiViewport
      composer
    }
    .padding(metrics.sectionPadding)
    .dynamicTypeSize(.xSmall ... .accessibility5)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      if tui?.status.isActive == true {
        focusedField = .composer
      }
    }
    .onChange(of: latestOutput) { _, output in
      announceOutputIfAllowed(output)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: metrics.headerSpacing) {
      Text(agent.name)
        .scaledFont(.title3.weight(.semibold))
        .lineLimit(1)
      Text("\(agent.runtime.uppercased()) • \(agent.role.title) • \(agent.status.title)")
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
  }

  private var tuiViewport: some View {
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
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(latestOutput))
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionAgentTuiViewport(agent.agentId))
      .onChange(of: tui?.screen.text ?? "") { _, _ in
        if let last = visibleRows.last {
          proxy.scrollTo(last.id, anchor: .bottom)
        }
      }
    }
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: metrics.composerSpacing) {
      TextEditor(text: $message)
        .scaledFont(.body)
        .frame(minHeight: metrics.composerMinHeight, maxHeight: metrics.composerMaxHeight)
        .focused($focusedField, equals: .composer)
        .accessibilityLabel("Agent message")
        .accessibilityIdentifier(HarnessMonitorAccessibility.sessionAgentComposer(agent.agentId))

      VStack(spacing: metrics.keyStackSpacing) {
        keyButton(.arrowUp)
        keyButton(.arrowDown)
        sendButton
      }
    }
  }

  private var sendButton: some View {
    Button {
      Task { await sendMessage() }
    } label: {
      Image(systemName: "paperplane.fill")
    }
    .keyboardShortcut(.return, modifiers: [.command])
    .help("Send Message")
    .accessibilityLabel("Send Message")
    .disabled(!canSendInput)
    .frame(minWidth: metrics.controlButtonMinSize, minHeight: metrics.controlButtonMinSize)
  }

  private func keyButton(_ key: AgentTuiKey) -> some View {
    Button {
      Task { await sendKey(key) }
    } label: {
      Text(key.glyph)
        .scaledFont(.body)
        .frame(width: metrics.keyButtonWidth)
    }
    .help(key.title)
    .accessibilityLabel(key.title)
    .disabled(tui?.status.isActive != true)
    .frame(minWidth: metrics.controlButtonMinSize, minHeight: metrics.controlButtonMinSize)
  }

  @MainActor
  private func sendMessage() async {
    guard let tui, canSendInput else { return }
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    message = ""
    _ = await store.sendAgentTuiInput(
      tuiID: tui.tuiId,
      input: .text("\(text)\n"),
      showSuccessFeedback: false
    )
    AccessibilityNotification.Announcement("Message sent. Waiting for agent reply.").post()
  }

  @MainActor
  private func sendKey(_ key: AgentTuiKey) async {
    guard let tui else { return }
    _ = await store.sendAgentTuiInput(
      tuiID: tui.tuiId,
      input: .key(key),
      showSuccessFeedback: false
    )
  }

  private func announceOutputIfAllowed(_ output: String) {
    guard !output.isEmpty else { return }
    let now = Date()
    guard now.timeIntervalSince(lastAnnouncementAt) >= 0.1 else { return }
    lastAnnouncementAt = now
    AccessibilityNotification.Announcement(output).post()
  }
}
