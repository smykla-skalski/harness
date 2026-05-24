import HarnessMonitorKit
import SwiftUI

/// Comment composer for the Reviews PR conversation tab. POD-first
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
struct DashboardReviewCommentComposer: View {
  let pullRequestID: String
  let initialDraft: String
  let viewerCanComment: Bool
  let fontScale: CGFloat
  let viewerLogin: String?
  let onDraftChange: (String) -> Void
  let onSend: (String) async -> ReviewCommentPostOutcome
  let bodyFont: Font
  let captionFont: Font
  let caption2Font: Font
  let caption2MonospacedFont: Font

  @State private var draft: String
  @State private var debouncedDraft: String
  // The character counter reads `draft.unicodeScalars.count` directly
  // so the figure stays in sync with the editor near the 60k soft cap.
  // `unicodeScalars.count` skips grapheme-cluster bookkeeping that
  // `String.count` triggers, so the cost is bounded even for a maxed
  // 65k draft (a few hundred microseconds on Apple silicon).
  @State private var showPreview: Bool = false
  @State private var isPosting = false
  @State private var lastError: String?
  // Retained across keystrokes so Retry resends what failed even if the
  // user has typed more characters into the editor since the failure.
  // Cleared on successful send or explicit dismiss.
  @State private var lastFailedBody: String?
  @FocusState private var focused: Bool
  // Collapse state lives per-detail-pane (not in `@AppStorage`) so the
  // user's collapse on one PR doesn't follow them to the next. The
  // parent applies `.id(pullRequestID)` on the composer so each PR
  // gets a fresh `@State` that starts expanded.
  @State private var isCollapsed: Bool = false

  // GitHub's hard limit is ~65,536 characters for issue/PR comments;
  // soft-warn at 60k so the user has room to abort before hitting the
  // ceiling.
  private static let softCharacterLimit = 60_000

  init(
    pullRequestID: String,
    initialDraft: String,
    viewerCanComment: Bool,
    fontScale: CGFloat,
    viewerLogin: String? = nil,
    onDraftChange: @escaping (String) -> Void,
    onSend: @escaping (String) async -> ReviewCommentPostOutcome
  ) {
    self.pullRequestID = pullRequestID
    self.initialDraft = initialDraft
    self.viewerCanComment = viewerCanComment
    self.fontScale = fontScale
    self.viewerLogin = viewerLogin
    self.onDraftChange = onDraftChange
    self.onSend = onSend
    bodyFont = HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
    captionFont = HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
    caption2Font = HarnessMonitorTextSize.scaledFont(.caption2, by: fontScale)
    caption2MonospacedFont = HarnessMonitorTextSize.scaledFont(
      .caption2.monospacedDigit(),
      by: fontScale
    )
    _draft = State(initialValue: initialDraft)
    _debouncedDraft = State(initialValue: initialDraft)
  }

  var body: some View {
    VStack(spacing: 0) {
      Divider().opacity(0.42)
      if let message = lastError {
        DashboardReviewCommentRetryStrip(
          message: message,
          fontScale: fontScale,
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
    .font(bodyFont)
    .animation(.smooth(duration: 0.18), value: isCollapsed)
    .task(id: draft) {
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      debouncedDraft = draft
      onDraftChange(draft)
    }
    .onExitCommand { focused = false }
    .onChange(of: isCollapsed) { _, collapsed in
      // Focus the editor only when the user explicitly expands the
      // composer. Auto-focusing on every detail-pane appearance traps
      // keyboard shortcuts (Cmd+W, arrow keys) inside the TextField
      // before the user has signalled intent to type.
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
          .font(captionFont)
      }
      .contentShape(.rect)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
    .harnessPlainButtonStyle()
    .disabled(!viewerCanComment)
    .help(
      viewerCanComment
        ? ""
        : "Your access token doesn't grant the `repo` / `pull_request` write scopes "
          + "for this repository. Check Settings → Connections."
    )
    .accessibilityLabel(Text("Expand comment composer"))
  }

  @ViewBuilder private var expandedComposer: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      editorOrPreview
      controlsRow
      hintsRow
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
          .font(captionFont)
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
      TextField("Add a comment…", text: $draft, axis: .vertical)
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
      Picker("", selection: $showPreview) {
        Text("Edit").tag(false)
        Text("Preview").tag(true)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .disabled(trimmed.isEmpty)
      .help(trimmed.isEmpty ? "Type a comment to preview it." : "")
      Spacer()
      Text("\(charCount) characters")
        .font(caption2MonospacedFont)
        .foregroundStyle(
          charCount > Self.softCharacterLimit ? .red : .secondary
        )
        .accessibilityLabel(
          Text("\(charCount) characters drafted")
        )
      Button("Send", action: send)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(trimmed.isEmpty || isPosting || !viewerCanComment)
        .accessibilityLabel(Text(isPosting ? "Sending comment" : "Send comment"))
        .harnessActionButtonStyle(variant: .prominent)
    }
  }

  @ViewBuilder private var hintsRow: some View {
    HStack(spacing: 8) {
      if let viewerLogin {
        Text("Commenting as @\(viewerLogin)")
          .accessibilityLabel(Text("Commenting as \(viewerLogin)"))
      }
      Spacer(minLength: 0)
      Text("⌘↩ to send · Markdown supported")
        .accessibilityLabel(Text("Command return to send. Markdown formatting supported."))
    }
    .font(caption2Font)
    .foregroundStyle(.tertiary)
  }

  private var charCount: Int {
    draft.unicodeScalars.count
  }

  private var trimmed: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func send() {
    sendBody(trimmed, clearOnSuccess: true)
  }

  /// Retry: resend the last failed body without disturbing whatever the
  /// user has since typed into the editor. If the failed body is
  /// recoverable the strip's "Restore" button can put it back into the
  /// editor, but a click on Retry alone leaves the editor untouched.
  private func retry() {
    guard let body = lastFailedBody, !isPosting else { return }
    sendBody(body, clearOnSuccess: false)
  }

  private func restoreFailedBody() {
    guard let body = lastFailedBody else { return }
    draft = body
    debouncedDraft = body
    lastError = nil
    lastFailedBody = nil
  }

  private func sendBody(_ body: String, clearOnSuccess: Bool) {
    isPosting = true
    Task {
      let outcome = await onSend(body)
      switch outcome {
      case .posted:
        if clearOnSuccess {
          draft = ""
          debouncedDraft = ""
          onDraftChange("")
        }
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

  private func dismissError() {
    lastError = nil
    lastFailedBody = nil
  }
}
