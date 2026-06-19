import AppKit
import Foundation
import HarnessMonitorKit
import SwiftUI

struct DashboardReviewConversationFullContent: Identifiable, Equatable, Sendable {
  let id: SessionTimelineNode.Identity
  let title: String
  let sourceLabel: String
  let markdown: String
}

enum DashboardReviewConversationFullContentResolver {
  static func resolve(
    node: SessionTimelineNode,
    entries: [ReviewTimelineEntry]
  ) -> DashboardReviewConversationFullContent? {
    guard node.canOpenFullContent else { return nil }
    guard let markdown = markdown(for: node.identity, entries: entries) else {
      return nil
    }
    return DashboardReviewConversationFullContent(
      id: node.identity,
      title: node.title,
      sourceLabel: node.sourceLabel,
      markdown: markdown
    )
  }

  private static func markdown(
    for identity: SessionTimelineNode.Identity,
    entries: [ReviewTimelineEntry]
  ) -> String? {
    guard case .entry(let entryID) = identity else { return nil }
    for entry in entries {
      switch entry {
      case .issueComment(let payload) where payload.id == entryID:
        return payload.isMinimized ? nil : trimmed(payload.body)
      case .review(let payload) where payload.id == entryID:
        return trimmed(payload.body)
      case .review(let payload):
        if let markdown = inlineCommentMarkdown(for: entryID, review: payload) {
          return markdown
        }
      case .reviewThread(let payload):
        if let markdown = threadCommentMarkdown(for: entryID, thread: payload) {
          return markdown
        }
      case .commit(let payload) where payload.id == entryID:
        return trimmed(payload.messageHeadline)
      default:
        continue
      }
    }
    return nil
  }

  private static func inlineCommentMarkdown(
    for entryID: String,
    review: ReviewPayload
  ) -> String? {
    for inlineComment in review.inlineComments where "\(review.id):\(inlineComment.id)" == entryID {
      return trimmed(inlineComment.body)
    }
    return nil
  }

  private static func threadCommentMarkdown(
    for entryID: String,
    thread: ReviewThreadPayload
  ) -> String? {
    for comment in thread.comments where "\(thread.id):\(comment.id)" == entryID {
      return trimmed(comment.body)
    }
    return nil
  }

  private static func trimmed(_ markdown: String?) -> String? {
    let trimmedMarkdown = (markdown ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMarkdown.isEmpty else { return nil }
    return trimmedMarkdown
  }
}

struct DashboardReviewConversationFullContentSheet: View {
  let content: DashboardReviewConversationFullContent
  let fontScale: CGFloat
  @State private var sheetMetrics = DashboardReviewConversationFullContentSheetMetrics.fallback

  private let preferredBodyWidth: CGFloat

  init(content: DashboardReviewConversationFullContent, fontScale: CGFloat) {
    self.content = content
    self.fontScale = fontScale
    preferredBodyWidth = DashboardReviewConversationFullContentSheetMetrics.preferredBodyWidth(
      for: content,
      fontScale: fontScale
    )
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          Text(verbatim: content.title)
            .font(HarnessMonitorTextSize.scaledFont(.title3.weight(.semibold), by: fontScale))
            .foregroundStyle(HarnessMonitorTheme.ink)
            .accessibilityAddTraits(.isHeader)
          Text(verbatim: content.sourceLabel)
            .font(HarnessMonitorTextSize.scaledFont(.subheadline, by: fontScale))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        Divider()
        HarnessMonitorMarkdownText(content.markdown, textSelection: .enabled)
      }
      .frame(width: sheetMetrics.bodyWidth(for: preferredBodyWidth), alignment: .leading)
      .padding(.top, HarnessMonitorTheme.spacingLG)
      .padding(.horizontal, HarnessMonitorTheme.spacingLG)
      .padding(.bottom, HarnessMonitorTheme.spacingLG)
    }
    .frame(width: sheetMetrics.contentWidth(for: preferredBodyWidth))
    .frame(maxHeight: sheetMetrics.maxHeight)
    .background(Color(nsColor: .windowBackgroundColor))
    .background(DashboardReviewConversationFullContentSheetMetricsReader(metrics: $sheetMetrics))
  }
}

struct DashboardReviewConversationFullContentSheetMetrics: Equatable {
  static let fallbackToolbarHeight: CGFloat = 52
  private static let minimumBodyWidth: CGFloat = 320
  private static let maximumMeasuredBodyWidth: CGFloat = 1_200

  static let fallback = Self(
    maxWidth: 760,
    maxHeight: 520,
    toolbarHeight: fallbackToolbarHeight
  )

  let maxWidth: CGFloat
  let maxHeight: CGFloat
  let toolbarHeight: CGFloat

  var maximumContentSize: CGSize {
    CGSize(width: maxWidth, height: maxHeight)
  }

  func contentWidth(for preferredBodyWidth: CGFloat) -> CGFloat {
    let paddedWidth = bodyWidth(for: preferredBodyWidth) + Self.horizontalPadding
    guard maxWidth > 0 else { return paddedWidth }
    return min(maxWidth, paddedWidth)
  }

  func bodyWidth(for preferredBodyWidth: CGFloat) -> CGFloat {
    let fittedWidth = max(Self.minimumBodyWidth, preferredBodyWidth)
    let availableBodyWidth = max(0, maxWidth - Self.horizontalPadding)
    guard availableBodyWidth > 0 else { return fittedWidth }
    return min(fittedWidth, availableBodyWidth)
  }

  static func preferredBodyWidth(
    for content: DashboardReviewConversationFullContent,
    fontScale: CGFloat
  ) -> CGFloat {
    let titleWidth = measuredLineWidth(
      content.title,
      font: .systemFont(ofSize: 20 * fontScale, weight: .semibold)
    )
    let sourceWidth = measuredLineWidth(
      content.sourceLabel,
      font: .systemFont(ofSize: 13 * fontScale)
    )
    let markdownWidth = preferredMarkdownWidth(content.markdown, fontScale: fontScale)
    return min(max(titleWidth, sourceWidth, markdownWidth), maximumMeasuredBodyWidth)
  }

  static func resolved(
    parentFrame: CGRect?,
    parentContentLayoutRect: CGRect?,
    sheetChromeSize: CGSize
  ) -> Self {
    guard let parentFrame else { return fallback }
    let toolbarHeight = resolvedToolbarHeight(
      parentFrame: parentFrame,
      parentContentLayoutRect: parentContentLayoutRect
    )
    return Self(
      maxWidth: max(0, parentFrame.width - (toolbarHeight * 2) - sheetChromeSize.width),
      maxHeight: max(0, parentFrame.height - (toolbarHeight * 2) - sheetChromeSize.height),
      toolbarHeight: toolbarHeight
    )
  }

  private static var horizontalPadding: CGFloat {
    HarnessMonitorTheme.spacingLG * 2
  }

  private static func resolvedToolbarHeight(
    parentFrame: CGRect,
    parentContentLayoutRect: CGRect?
  ) -> CGFloat {
    guard let parentContentLayoutRect else { return fallbackToolbarHeight }
    let measured = parentFrame.height - parentContentLayoutRect.height
    guard measured.isFinite, measured > 0 else { return fallbackToolbarHeight }
    return measured
  }

  private static func preferredMarkdownWidth(_ markdown: String, fontScale: CGFloat) -> CGFloat {
    let bodyFont = NSFont.systemFont(ofSize: 15 * fontScale)
    let codeFont = NSFont.monospacedSystemFont(ofSize: 14 * fontScale, weight: .regular)
    var maxWidth: CGFloat = 0
    for line in markdown.components(separatedBy: .newlines) {
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)
      guard !trimmedLine.isEmpty else { continue }
      let font = trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("    ") ? codeFont : bodyFont
      maxWidth = max(maxWidth, measuredLineWidth(trimmedLine, font: font))
    }
    return maxWidth
  }

  private static func measuredLineWidth(_ line: String, font: NSFont) -> CGFloat {
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let size = (line as NSString).boundingRect(
      with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: attributes
    ).size
    guard size.width.isFinite else { return 0 }
    return ceil(size.width)
  }
}

private struct DashboardReviewConversationFullContentSheetMetricsReader: NSViewRepresentable {
  @Binding var metrics: DashboardReviewConversationFullContentSheetMetrics

  func makeNSView(context: Context) -> MetricsView {
    let view = MetricsView()
    view.onMetricsChange = updateMetrics(_:)
    return view
  }

  func updateNSView(_ nsView: MetricsView, context: Context) {
    nsView.onMetricsChange = updateMetrics(_:)
    nsView.scheduleRefresh()
  }

  private func updateMetrics(_ nextMetrics: DashboardReviewConversationFullContentSheetMetrics) {
    DispatchQueue.main.async {
      guard metrics != nextMetrics else { return }
      metrics = nextMetrics
    }
  }

  final class MetricsView: NSView {
    private var appliedSizing: AppliedSizing?
    private var refreshScheduled = false
    private var parentWindowRetryCount = 0
    var onMetricsChange: ((DashboardReviewConversationFullContentSheetMetrics) -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      scheduleRefresh()
    }

    func scheduleRefresh() {
      guard !refreshScheduled else { return }
      refreshScheduled = true
      Task { @MainActor [weak self] in
        self?.refreshScheduled = false
        self?.refreshMetrics()
      }
    }

    func refreshMetrics() {
      guard let sheetWindow = window else { return }
      guard let parentWindow = parentWindow(for: sheetWindow) else {
        scheduleParentWindowRetry()
        return
      }
      parentWindowRetryCount = 0
      let metrics = DashboardReviewConversationFullContentSheetMetrics.resolved(
        parentFrame: parentWindow.frame,
        parentContentLayoutRect: parentWindow.contentLayoutRect,
        sheetChromeSize: frameChromeSize(for: sheetWindow)
      )
      apply(metrics, to: sheetWindow)
    }

    private func apply(
      _ metrics: DashboardReviewConversationFullContentSheetMetrics,
      to sheetWindow: NSWindow?
    ) {
      guard let sheetWindow else { return }
      guard metrics.maxWidth > 0, metrics.maxHeight > 0 else { return }
      sheetWindow.contentMaxSize = metrics.maximumContentSize
      onMetricsChange?(metrics)
      let sizing = AppliedSizing(maximumContentSize: metrics.maximumContentSize)
      guard appliedSizing != sizing else { return }
      appliedSizing = sizing
    }

    private func parentWindow(for sheetWindow: NSWindow) -> NSWindow? {
      if let sheetParent = sheetWindow.sheetParent {
        return sheetParent
      }
      let candidates = NSApp.windows.filter { candidate in
        candidate !== sheetWindow
          && candidate.isVisible
          && !candidate.isMiniaturized
          && candidate.styleMask.contains(.titled)
          && !candidate.isExcludedFromWindowsMenu
      }
      if let overlapping = candidates.max(by: {
        intersectionArea($0.frame, sheetWindow.frame)
          < intersectionArea($1.frame, sheetWindow.frame)
      }), intersectionArea(overlapping.frame, sheetWindow.frame) > 0 {
        return overlapping
      }
      if let keyWindow = NSApp.keyWindow, candidates.contains(where: { $0 === keyWindow }) {
        return keyWindow
      }
      if let mainWindow = NSApp.mainWindow, candidates.contains(where: { $0 === mainWindow }) {
        return mainWindow
      }
      return candidates.first
    }

    private func scheduleParentWindowRetry() {
      guard parentWindowRetryCount < 3 else { return }
      parentWindowRetryCount += 1
      scheduleRefresh()
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
      let intersection = lhs.intersection(rhs)
      guard !intersection.isNull else { return 0 }
      return max(0, intersection.width) * max(0, intersection.height)
    }

    private func frameChromeSize(for sheetWindow: NSWindow) -> CGSize {
      let contentRect = NSRect(x: 0, y: 0, width: 100, height: 100)
      let frameRect = sheetWindow.frameRect(forContentRect: contentRect)
      return CGSize(
        width: max(0, frameRect.width - contentRect.width),
        height: max(0, frameRect.height - contentRect.height)
      )
    }

    private struct AppliedSizing: Equatable {
      let maximumContentSize: CGSize
    }
  }
}
