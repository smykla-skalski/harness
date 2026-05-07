import HarnessMonitorKit
import SwiftUI

struct SessionAgentDetailSection: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let agent: AgentRegistration
  let tui: AgentTuiSnapshot?
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

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      tuiViewport
      composer
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task(id: agent.agentId) {
      if tui?.status.isActive == true {
        focusedField = .composer
      }
    }
    .onChange(of: latestOutput) { _, output in
      announceOutputIfAllowed(output)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(agent.name)
        .font(.title3.weight(.semibold))
        .lineLimit(1)
      Text("\(agent.runtime.uppercased()) • \(agent.role.title) • \(agent.status.title)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
  }

  private var tuiViewport: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          if visibleRows.isEmpty {
            Text(tui == nil ? "No terminal attached" : "No terminal output")
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            ForEach(visibleRows) { row in
              Text(row.text.isEmpty ? " " : row.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(row.id)
            }
          }
        }
        .padding(12)
      }
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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
    HStack(alignment: .bottom, spacing: 8) {
      TextEditor(text: $message)
        .font(.body)
        .frame(minHeight: 46, maxHeight: 120)
        .focused($focusedField, equals: .composer)
        .accessibilityLabel("Agent message")
        .accessibilityIdentifier(HarnessMonitorAccessibility.sessionAgentComposer(agent.agentId))

      VStack(spacing: 6) {
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
  }

  private func keyButton(_ key: AgentTuiKey) -> some View {
    Button {
      Task { await sendKey(key) }
    } label: {
      Text(key.glyph)
        .frame(width: 22)
    }
    .help(key.title)
    .accessibilityLabel(key.title)
    .disabled(tui?.status.isActive != true)
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
