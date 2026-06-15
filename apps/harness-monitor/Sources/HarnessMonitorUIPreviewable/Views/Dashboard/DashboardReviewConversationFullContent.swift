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
      .frame(maxWidth: sheetMetrics.maxWidth, alignment: .leading)
      .padding(.top, HarnessMonitorTheme.spacingLG)
      .padding(.horizontal, HarnessMonitorTheme.spacingLG)
      .padding(.bottom, sheetMetrics.toolbarHeight)
    }
    .frame(maxWidth: sheetMetrics.maxWidth, maxHeight: sheetMetrics.maxHeight)
    .background(Color(nsColor: .windowBackgroundColor))
    .background(
      DashboardReviewConversationFullContentSheetMetricsReader(metrics: $sheetMetrics)
    )
  }
}

struct DashboardReviewConversationFullContentSheetMetrics: Equatable {
  static let fallbackToolbarHeight: CGFloat = 52
  static let minimumHeight: CGFloat = 420

  static let fallback = Self(
    maxWidth: 760,
    maxHeight: 520,
    toolbarHeight: fallbackToolbarHeight
  )

  let maxWidth: CGFloat
  let maxHeight: CGFloat
  let toolbarHeight: CGFloat

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
      maxHeight: max(minimumHeight, parentFrame.height - toolbarHeight),
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
  @Binding var metrics: DashboardReviewConversationFullContentSheetMetrics

  func makeNSView(context: Context) -> MetricsView {
    let view = MetricsView()
    view.onMetricsChange = { metrics = $0 }
    return view
  }

  func updateNSView(_ nsView: MetricsView, context: Context) {
    nsView.onMetricsChange = { metrics = $0 }
    nsView.refreshMetrics()
  }

  final class MetricsView: NSView {
    var onMetricsChange: ((DashboardReviewConversationFullContentSheetMetrics) -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      refreshMetrics()
    }

    func refreshMetrics() {
      let parentWindow = window?.sheetParent ?? window
      let metrics = DashboardReviewConversationFullContentSheetMetrics.resolved(
        parentFrame: parentWindow?.frame,
        parentContentLayoutRect: parentWindow?.contentLayoutRect
      )
      onMetricsChange?(metrics)
    }
  }
}
