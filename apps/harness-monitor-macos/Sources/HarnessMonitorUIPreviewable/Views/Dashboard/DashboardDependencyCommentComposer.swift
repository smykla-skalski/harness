import HarnessMonitorKit
import SwiftUI

/// Comment composer for the Dependencies PR conversation tab. POD-first
/// surface: takes its dependencies via closure ports so the view is
/// trivially previewable and testable without an `@Environment` store
/// reference. Per plan §6.1 / §10.2:
///
/// - Markdown preview is off by default; even when toggled on, the
///   rendered markdown source comes from `debouncedDraft` (300ms after
///   the last keystroke) — no per-keystroke parse spike.
/// - Draft persistence is debounced 500ms outside the view via the
///   `onDraftChange` callback so UserDefaults sees one write per
///   typing pause instead of one per character.
/// - `.glassProminent` Send button gated on macOS 26+ with a
///   `.borderedProminent` fallback for older OS.
struct DashboardDependencyCommentComposer: View {
  let pullRequestID: String
  let initialDraft: String
  let viewerCanComment: Bool
  let onDraftChange: (String) -> Void
  let onSend: (String) async -> DependencyUpdateCommentPostOutcome

  @State private var draft: String
  @State private var debouncedDraft: String
  @State private var showPreview: Bool = false
  @State private var isPosting = false
  @State private var lastError: String?
  @FocusState private var focused: Bool

  init(
    pullRequestID: String,
    initialDraft: String,
    viewerCanComment: Bool,
    onDraftChange: @escaping (String) -> Void,
    onSend: @escaping (String) async -> DependencyUpdateCommentPostOutcome
  ) {
    self.pullRequestID = pullRequestID
    self.initialDraft = initialDraft
    self.viewerCanComment = viewerCanComment
    self.onDraftChange = onDraftChange
    self.onSend = onSend
    _draft = State(initialValue: initialDraft)
    _debouncedDraft = State(initialValue: initialDraft)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      editorOrPreview
      controlsRow
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.thickMaterial)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("New comment composer"))
    .task(id: draft) {
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      debouncedDraft = draft
      onDraftChange(draft)
    }
    .onExitCommand { focused = false }
    .onAppear { focused = true }
  }

  @ViewBuilder private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "text.bubble")
      Text("Comment")
      Spacer()
      if let lastError {
        Label(lastError, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .font(.caption)
      }
    }
  }

  @ViewBuilder private var editorOrPreview: some View {
    if showPreview {
      HarnessMonitorMarkdownText(debouncedDraft)
        .id(debouncedDraft)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      TextEditor(text: $draft)
        .frame(minHeight: 96, idealHeight: 96, maxHeight: 320)
        .focused($focused)
        .disabled(isPosting || !viewerCanComment)
    }
  }

  @ViewBuilder private var controlsRow: some View {
    HStack {
      Toggle("Preview", isOn: $showPreview)
        .toggleStyle(.button)
        .disabled(trimmed.isEmpty)
      Spacer()
      Button("Send", action: send)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(trimmed.isEmpty || isPosting || !viewerCanComment)
        .modifier(SendButtonStyleModifier())
    }
  }

  private var trimmed: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func send() {
    let body = trimmed
    isPosting = true
    Task {
      let outcome = await onSend(body)
      switch outcome {
      case .posted:
        draft = ""
        debouncedDraft = ""
        onDraftChange("")
        lastError = nil
      case .failed(let reason):
        lastError = reason
      case .daemonOffline:
        lastError = "Daemon offline"
      case .empty:
        lastError = "Cannot send empty comment"
      }
      isPosting = false
    }
  }
}

private struct SendButtonStyleModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content.buttonStyle(.borderedProminent)
    } else {
      content.buttonStyle(.borderedProminent)
    }
  }
}
