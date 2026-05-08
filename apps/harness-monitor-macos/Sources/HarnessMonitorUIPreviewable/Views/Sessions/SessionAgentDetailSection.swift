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
  @State private var composerBackdropHeight: CGFloat = 0
  @State private var lastAnnouncementAt = Date.distantPast
  @FocusState private var focusedField: SessionAgentComposerField?

  private var latestOutput: String {
    let rows = tui?.screen.visibleRows(maxRows: 1) ?? []
    return rows.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No output"
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
      SessionAgentTuiViewport(
        agentID: agent.agentId,
        tui: tui,
        metrics: metrics,
        latestOutput: latestOutput
      )
      SessionAgentComposer(
        agentID: agent.agentId,
        message: $message,
        focusedField: $focusedField,
        backdropHeight: $composerBackdropHeight,
        metrics: metrics,
        isActive: tui?.status.isActive == true,
        canSendInput: canSendInput,
        sendMessage: { Task { await sendMessage() } },
        sendKey: { key in Task { await sendKey(key) } }
      )
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
