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
  let quotedDiffContext: DashboardReviewActivityQuotedDiffContext?
  let truncationNotice: String?
  let onResolveToggle: (Bool) async -> Void
  let onReply: (String) async -> Bool

  // Collapse is per-card local state seeded from the thread so a collapsed
  // thread renders compact without the host having to track expansion.
  private let externalCollapsed: Binding<Bool>?
  @State private var localIsCollapsed: Bool
  @State private var replyText = ""
  @State private var isReplying = false
  @State private var isResolving = false
  @State private var replyFailed = false

  init(
    model: DashboardReviewInlineThreadCardModel,
    viewerLogin: String? = nil,
    fontScale: CGFloat = 1,
    loadAvatar: TimelineAvatarImageLoader? = nil,
    quotedDiffContext: DashboardReviewActivityQuotedDiffContext? = nil,
    truncationNotice: String? = nil,
    collapsed: Binding<Bool>? = nil,
    onResolveToggle: @escaping (Bool) async -> Void,
    onReply: @escaping (String) async -> Bool
  ) {
    self.model = model
    self.viewerLogin = viewerLogin
    self.fontScale = fontScale
    self.loadAvatar = loadAvatar
    self.quotedDiffContext = quotedDiffContext
    self.truncationNotice = truncationNotice
    externalCollapsed = collapsed
    self.onResolveToggle = onResolveToggle
    self.onReply = onReply
    _localIsCollapsed = State(initialValue: collapsed?.wrappedValue ?? model.thread.isCollapsed)
  }

  var body: some View {
    let headerCenterOffset = 14 * max(1, fontScale)
    VStack(alignment: .leading, spacing: 0) {
      header
      if !isCollapsed {
        if let quotedDiffContext {
          quotedDiffContextSection(quotedDiffContext)
            .padding(.top, 8)
        }
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
    .alignmentGuide(.sessionTimelineFirstLineCenter) { dimensions in
      dimensions[VerticalAlignment.top] + headerCenterOffset
    }
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
      setCollapsed(!isCollapsed)
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

  @ViewBuilder
  private func quotedDiffContextSection(
    _ context: DashboardReviewActivityQuotedDiffContext
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(context.path)
          .font(caption2.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
          .lineLimit(1)
        Text(context.locationLabel)
          .font(caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if !context.lines.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(context.lines) { line in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(verbatim: line.prefix)
                .font(caption2.monospaced())
                .foregroundStyle(diffLineTint(for: line.kind))
              Text(verbatim: line.text)
                .font(caption2.monospaced())
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(diffLineBackground(for: line.kind))
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(HarnessMonitorTheme.controlBorder.opacity(0.5), lineWidth: 1)
        }
      }
    }
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
      if let truncationNotice {
        Text(truncationNotice)
          .font(caption2)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
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

  private var isCollapsed: Bool {
    externalCollapsed?.wrappedValue ?? localIsCollapsed
  }

  private var replyPrompt: String {
    viewerLogin.map { "Reply as @\($0)…" } ?? "Reply…"
  }

  private func setCollapsed(_ collapsed: Bool) {
    if let externalCollapsed {
      externalCollapsed.wrappedValue = collapsed
    } else {
      localIsCollapsed = collapsed
    }
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

  private func diffLineTint(
    for kind: DashboardReviewActivityQuotedDiffLine.Kind
  ) -> Color {
    switch kind {
    case .addition:
      .green
    case .deletion:
      .red
    case .context, .overflow:
      HarnessMonitorTheme.secondaryInk
    }
  }

  private func diffLineBackground(
    for kind: DashboardReviewActivityQuotedDiffLine.Kind
  ) -> Color {
    switch kind {
    case .addition:
      Color.green.opacity(0.08)
    case .deletion:
      Color.red.opacity(0.08)
    case .context, .overflow:
      Color(nsColor: .controlBackgroundColor).opacity(0.35)
    }
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
