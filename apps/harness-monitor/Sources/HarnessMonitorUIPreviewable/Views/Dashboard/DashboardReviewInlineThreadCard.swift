import HarnessMonitorKit
import SwiftUI

/// GitHub-style inline review conversation card rendered between diff lines.
/// POD-first: the diff host injects async resolve/reply ports so the card has
/// no `@Environment` store dependency and stays previewable and testable. One
/// card renders one ``DashboardReviewFileThread`` with every comment inline.
struct DashboardReviewInlineThreadCard: View {
  let model: DashboardReviewInlineThreadCardModel
  let viewerLogin: String?
  let fontScale: CGFloat
  let loadAvatar: TimelineAvatarImageLoader?
  let onResolveToggle: (Bool) async -> Void
  let onReply: (String) async -> Bool

  // Collapse is per-card local state seeded from the thread so a collapsed
  // thread renders compact without the host having to track expansion.
  @State private var isCollapsed: Bool
  @State private var replyText = ""
  @State private var isReplying = false
  @State private var isResolving = false
  @State private var replyFailed = false

  init(
    model: DashboardReviewInlineThreadCardModel,
    viewerLogin: String? = nil,
    fontScale: CGFloat = 1,
    loadAvatar: TimelineAvatarImageLoader? = nil,
    onResolveToggle: @escaping (Bool) async -> Void,
    onReply: @escaping (String) async -> Bool
  ) {
    self.model = model
    self.viewerLogin = viewerLogin
    self.fontScale = fontScale
    self.loadAvatar = loadAvatar
    self.onResolveToggle = onResolveToggle
    self.onReply = onReply
    _isCollapsed = State(initialValue: model.thread.isCollapsed)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if !isCollapsed {
        Divider().opacity(0.4).padding(.vertical, 6)
        comments
        footer
      }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .background(cardBackground)
    .overlay(cardBorder)
    .animation(.smooth(duration: 0.16), value: isCollapsed)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Review conversation on \(model.lineReference)"))
    .accessibilityIdentifier("dashboardReviewInlineThreadCard")
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      AvatarImageView(
        login: model.headerAuthorLogin,
        avatarURL: model.thread.comments.first?.authorAvatarURL,
        size: 18,
        loadImage: loadAvatar
      )
      Text("@\(model.headerAuthorLogin)").font(captionSemibold)
      Text(model.lineReference)
        .font(caption2)
        .foregroundStyle(.secondary)
      if let chip = model.resolvedChipText {
        resolvedChip(chip)
      }
      Spacer(minLength: 6)
      Text(model.commentSummary)
        .font(caption2.monospacedDigit())
        .foregroundStyle(.secondary)
      collapseButton
    }
  }

  private var collapseButton: some View {
    Button {
      isCollapsed.toggle()
    } label: {
      Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
        .font(caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(.rect)
    }
    .harnessPlainButtonStyle()
    .help(isCollapsed ? "Expand conversation" : "Collapse conversation")
    .accessibilityLabel(Text(isCollapsed ? "Expand conversation" : "Collapse conversation"))
  }

  private func resolvedChip(_ text: String) -> some View {
    Text(text)
      .font(caption2.weight(.semibold))
      .foregroundStyle(.green)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.green.opacity(0.14), in: Capsule())
  }

  // MARK: - Comments

  private var comments: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(model.thread.comments) { comment in
        commentRow(comment)
      }
    }
  }

  private func commentRow(_ comment: DashboardReviewFileThreadComment) -> some View {
    HStack(alignment: .top, spacing: 8) {
      AvatarImageView(
        login: comment.authorLogin ?? "ghost",
        avatarURL: comment.authorAvatarURL,
        size: 20,
        loadImage: loadAvatar
      )
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text("@\(comment.authorLogin ?? "ghost")")
            .font(caption2.weight(.semibold))
          Text(formatRelativeUpdatedAt(comment.createdAt))
            .font(caption2)
            .foregroundStyle(.secondary)
        }
        HarnessMonitorMarkdownText(comment.body, font: bodyFont, textSelection: .enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  // MARK: - Footer (resolve + reply)

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button(action: resolve) {
          Label(model.resolveActionTitle, systemImage: model.resolveActionSystemImage)
        }
        .controlSize(.small)
        .disabled(isResolving)
        .accessibilityIdentifier("dashboardReviewInlineThreadResolveButton")
        Spacer(minLength: 6)
        if isResolving || isReplying {
          ProgressView().controlSize(.mini)
        }
      }
      replyField
      if replyFailed {
        Text("Couldn't post the reply. Check your connection and try again.")
          .font(caption2)
          .foregroundStyle(.red)
      }
    }
    .padding(.top, 8)
  }

  private var replyField: some View {
    HStack(spacing: 8) {
      TextField(replyPrompt, text: $replyText, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...6)
        .font(bodyFont)
        .disabled(isReplying)
        .onSubmit(reply)
        .accessibilityLabel(Text("Reply to conversation"))
        .accessibilityIdentifier("dashboardReviewInlineThreadReplyField")
      Button("Reply", action: reply)
        .controlSize(.small)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(trimmedReply.isEmpty || isReplying)
    }
  }

  // MARK: - Actions

  private var trimmedReply: String {
    replyText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var replyPrompt: String {
    viewerLogin.map { "Reply as @\($0)…" } ?? "Reply…"
  }

  private func resolve() {
    guard !isResolving else { return }
    isResolving = true
    Task {
      await onResolveToggle(!model.isResolved)
      isResolving = false
    }
  }

  private func reply() {
    let body = trimmedReply
    guard !body.isEmpty, !isReplying else { return }
    isReplying = true
    replyFailed = false
    Task {
      let posted = await onReply(body)
      if posted {
        replyText = ""
      } else {
        replyFailed = true
      }
      isReplying = false
    }
  }

  // MARK: - Chrome

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
  }

  private var cardBorder: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .stroke(
        model.isResolved
          ? Color.green.opacity(0.4)
          : Color(nsColor: .separatorColor).opacity(0.7),
        lineWidth: 1
      )
  }

  private var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  private var caption2: Font {
    HarnessMonitorTextSize.scaledFont(.caption2, by: fontScale)
  }
}
