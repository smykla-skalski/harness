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
  // `String.count` walks grapheme clusters → O(n) per call. For a
  // 65k-character draft typed actively, that's 65k Unicode scans per
  // keystroke. `unicodeScalars.count` skips grapheme clustering and is
  // cheaper for display. Compute it inside the debounced task so the
  // figure updates 300ms after the user stops typing — not per keystroke.
  @State private var debouncedCharCount: Int = 0
  @State private var showPreview: Bool = false
  @State private var isPosting = false
  @State private var lastError: String?
  // Retained across keystrokes so Retry resends what failed even if the
  // user has typed more characters into the editor since the failure.
  // Cleared on successful send or explicit dismiss.
  @State private var lastFailedBody: String?
  @FocusState private var focused: Bool
  // Persistent collapse preference shared across all dependency PR
  // detail panes. Default expanded so first-time users see the editor.
  @AppStorage(Self.collapsedDefaultsKey)
  private var isCollapsed: Bool = false

  // GitHub's hard limit is ~65,536 characters for issue/PR comments;
  // soft-warn at 60k so the user has room to abort before hitting the
  // ceiling.
  private static let softCharacterLimit = 60_000
  private static let collapsedDefaultsKey = "DashboardDependencyComposer.isCollapsed"

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
    _debouncedCharCount = State(initialValue: initialDraft.unicodeScalars.count)
  }

  var body: some View {
    VStack(spacing: 0) {
      Divider().opacity(0.42)
      if let message = lastError {
        DashboardDependencyCommentRetryStrip(
          message: message,
          canRetry: lastFailedBody != nil && !isPosting,
          onRetry: retry,
          onDismiss: dismissError
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
      }
      if isCollapsed {
        collapsedBar
      } else {
        expandedComposer
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("New comment composer"))
    .animation(.smooth(duration: 0.18), value: isCollapsed)
    .task(id: draft) {
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      debouncedDraft = draft
      debouncedCharCount = draft.unicodeScalars.count
      onDraftChange(draft)
    }
    .onExitCommand { focused = false }
    .onAppear {
      if !isCollapsed && viewerCanComment { focused = true }
    }
    .onChange(of: isCollapsed) { _, collapsed in
      guard !collapsed, viewerCanComment else { return }
      Task {
        try? await Task.sleep(for: .milliseconds(120))
        focused = true
      }
    }
  }

  @ViewBuilder private var collapsedBar: some View {
    Button {
      isCollapsed = false
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "text.bubble")
        Text(viewerCanComment ? "Add a comment…" : "Comments disabled")
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Image(systemName: "chevron.up")
          .foregroundStyle(.tertiary)
          .font(.caption)
      }
      .contentShape(.rect)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
    .harnessPlainButtonStyle()
    .disabled(!viewerCanComment)
    .accessibilityLabel(Text("Expand comment composer"))
  }

  @ViewBuilder private var expandedComposer: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      editorOrPreview
      controlsRow
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  @ViewBuilder private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "text.bubble")
      Text("Comment")
      Spacer()
      Button {
        isCollapsed = true
      } label: {
        Image(systemName: "chevron.down")
          .foregroundStyle(.secondary)
          .font(.caption)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .contentShape(.rect)
      }
      .harnessPlainButtonStyle()
      .help("Collapse composer")
      .accessibilityLabel(Text("Collapse comment composer"))
    }
  }

  @ViewBuilder private var editorOrPreview: some View {
    if showPreview {
      HarnessMonitorMarkdownText(debouncedDraft)
        .id(debouncedDraft)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      TextField("Write a comment…", text: $draft, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(2...10)
        .focused($focused)
        .disabled(isPosting || !viewerCanComment)
        .accessibilityLabel(Text("Comment body"))
        .accessibilityValue(Text("\(draft.count) characters"))
    }
  }

  @ViewBuilder private var controlsRow: some View {
    HStack {
      Toggle("Preview", isOn: $showPreview)
        .toggleStyle(.button)
        .disabled(trimmed.isEmpty)
      Spacer()
      Text("\(debouncedCharCount) characters")
        .font(.caption2.monospacedDigit())
        .foregroundStyle(
          debouncedCharCount > Self.softCharacterLimit ? .red : .secondary
        )
        .accessibilityLabel(
          Text("\(debouncedCharCount) characters drafted")
        )
      Button("Send", action: send)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(trimmed.isEmpty || isPosting || !viewerCanComment)
        .accessibilityLabel(Text(isPosting ? "Sending comment" : "Send comment"))
        .harnessActionButtonStyle(variant: .prominent)
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
        debouncedCharCount = 0
        onDraftChange("")
        lastError = nil
        lastFailedBody = nil
      case .failed(let reason):
        lastError = reason
        lastFailedBody = body
      case .daemonOffline:
        lastError = "Daemon offline"
        lastFailedBody = body
      case .empty:
        lastError = "Cannot send empty comment"
        // No retry body to retain — the empty path can't recover by
        // re-invoking with the same input.
        lastFailedBody = nil
      }
      isPosting = false
    }
  }

  private func retry() {
    guard let body = lastFailedBody, !isPosting else { return }
    // Restore the editor to the failed body so the user SEES exactly
    // what's about to resend. Avoids the "phantom retry" UX bug where
    // the editor has diverged since the failure.
    draft = body
    debouncedDraft = body
    debouncedCharCount = body.unicodeScalars.count
    send()
  }

  private func dismissError() {
    lastError = nil
    lastFailedBody = nil
  }
}
