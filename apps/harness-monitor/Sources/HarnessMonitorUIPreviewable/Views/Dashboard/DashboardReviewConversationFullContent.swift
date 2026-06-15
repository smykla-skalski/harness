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
      .padding(.top, HarnessMonitorTheme.spacingLG)
      .padding(.horizontal, HarnessMonitorTheme.spacingLG)
      .padding(.bottom, HarnessMonitorTheme.spacingLG)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .background(DashboardReviewConversationFullContentSheetMetricsReader())
  }
}

struct DashboardReviewConversationFullContentSheetMetrics: Equatable {
  static let fallbackToolbarHeight: CGFloat = 52
  private static let defaultMinimumWidth: CGFloat = 360
  private static let defaultIdealWidth: CGFloat = 760
  private static let defaultMinimumHeight: CGFloat = 420
  private static let defaultIdealHeight: CGFloat = 520

  static let fallback = Self(
    maxWidth: 760,
    maxHeight: 520,
    toolbarHeight: fallbackToolbarHeight
  )

  let maxWidth: CGFloat
  let maxHeight: CGFloat
  let toolbarHeight: CGFloat

  var minimumWidth: CGFloat {
    min(Self.defaultMinimumWidth, maxWidth)
  }

  var idealWidth: CGFloat {
    min(Self.defaultIdealWidth, maxWidth)
  }

  var minimumHeight: CGFloat {
    min(Self.defaultMinimumHeight, maxHeight)
  }

  var idealHeight: CGFloat {
    min(Self.defaultIdealHeight, maxHeight)
  }

  var minimumContentSize: CGSize {
    CGSize(width: minimumWidth, height: minimumHeight)
  }

  func maximumContentSize(chromeSize: CGSize) -> CGSize {
    CGSize(
      width: max(0, maxWidth - chromeSize.width),
      height: max(0, maxHeight - chromeSize.height)
    )
  }

  func cappedContentSize(for preferredSize: CGSize, chromeSize: CGSize) -> CGSize {
    let maximumSize = maximumContentSize(chromeSize: chromeSize)
    return CGSize(
      width: min(preferredSize.width, maximumSize.width),
      height: min(preferredSize.height, maximumSize.height)
    )
  }

  static func resolved(
    parentFrame: CGRect?,
    parentContentLayoutRect: CGRect?
  ) -> Self {
    guard let parentFrame else { return fallback }
    let toolbarHeight = resolvedToolbarHeight(
      parentFrame: parentFrame,
      parentContentLayoutRect: parentContentLayoutRect
    )
    return Self(
      maxWidth: max(0, parentFrame.width - (toolbarHeight * 2)),
      maxHeight: max(0, parentFrame.height - (toolbarHeight * 2)),
      toolbarHeight: toolbarHeight
    )
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
}

private struct DashboardReviewConversationFullContentSheetMetricsReader: NSViewRepresentable {
  func makeNSView(context: Context) -> MetricsView {
    MetricsView()
  }

  func updateNSView(_ nsView: MetricsView, context: Context) {
    nsView.scheduleRefresh()
  }

  final class MetricsView: NSView {
    private var appliedSizing: AppliedSizing?
    private var refreshScheduled = false

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
      let sheetWindow = window
      let parentWindow = sheetWindow?.sheetParent ?? sheetWindow
      let metrics = DashboardReviewConversationFullContentSheetMetrics.resolved(
        parentFrame: parentWindow?.frame,
        parentContentLayoutRect: parentWindow?.contentLayoutRect
      )
      apply(metrics, to: sheetWindow)
    }

    private func apply(
      _ metrics: DashboardReviewConversationFullContentSheetMetrics,
      to sheetWindow: NSWindow?
    ) {
      guard let sheetWindow else { return }
      let chromeSize = frameChromeSize(for: sheetWindow)
      let maximumContentSize = metrics.maximumContentSize(chromeSize: chromeSize)
      guard maximumContentSize.width > 0, maximumContentSize.height > 0 else { return }
      sheetWindow.contentMaxSize = maximumContentSize
      sheetWindow.contentView?.layoutSubtreeIfNeeded()
      let currentSize = sheetWindow.contentLayoutRect.size
      let preferredSize = preferredContentSize(in: sheetWindow)
      let cappedSize = metrics.cappedContentSize(for: preferredSize, chromeSize: chromeSize)
      let sizing = AppliedSizing(maximumContentSize: maximumContentSize, targetContentSize: cappedSize)
      guard appliedSizing != sizing else { return }
      appliedSizing = sizing
      guard
        abs(currentSize.width - cappedSize.width) > 0.5
          || abs(currentSize.height - cappedSize.height) > 0.5
      else {
        return
      }
      sheetWindow.setContentSize(cappedSize)
    }

    private func preferredContentSize(in sheetWindow: NSWindow) -> CGSize {
      let fittingSize = sheetWindow.contentView?.fittingSize ?? .zero
      guard
        fittingSize.width.isFinite,
        fittingSize.height.isFinite,
        fittingSize.width > 0,
        fittingSize.height > 0
      else {
        return sheetWindow.contentLayoutRect.size
      }
      return fittingSize
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
      let targetContentSize: CGSize
    }
  }
}
