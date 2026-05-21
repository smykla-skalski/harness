import AppKit
import SwiftUI

struct HarnessMarkdownDetailsView: View {
  let details: HarnessMarkdownDetails
  let settings: HarnessMarkdownRenderSettings
  let style: HarnessMarkdownResolvedRenderSettings

  @State private var isExpanded: Bool

  init(
    details: HarnessMarkdownDetails,
    settings: HarnessMarkdownRenderSettings,
    style: HarnessMarkdownResolvedRenderSettings
  ) {
    self.details = details
    self.settings = settings
    self.style = style
    _isExpanded = State(initialValue: details.isOpen)
  }

  var body: some View {
    let metrics = HarnessMarkdownMarkerMetrics(style: style)
    VStack(alignment: .leading, spacing: 0) {
      summaryButton(metrics: metrics)
      if isExpanded {
        detailsSeparator
        detailsContent
      }
    }
    .background(cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(cardBorder)
  }

  private func summaryButton(metrics: HarnessMarkdownMarkerMetrics) -> some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack(alignment: .top, spacing: metrics.gap) {
        chevron(metrics: metrics)
        summaryText(metrics: metrics)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(cardPadding)
    }
    .buttonStyle(.borderless)
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(HarnessMarkdownPointerHoverModifier(color: style.colors.link))
    .accessibilityLabel(Text(HarnessMarkdownInlinePlainText.string(from: details.summary)))
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
  }

  private func chevron(metrics: HarnessMarkdownMarkerMetrics) -> some View {
    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
      .font(.system(size: max(metrics.chevronSize + 2, 12), weight: .bold))
      .foregroundStyle(style.colors.link)
      .frame(
        width: metrics.chevronColumnWidth,
        height: metrics.firstLineHeight,
        alignment: .center
      )
  }

  private func summaryText(metrics: HarnessMarkdownMarkerMetrics) -> some View {
    HarnessMarkdownInlineFlowView(
      inlines: details.summary,
      style: HarnessMarkdownInlineRenderStyle(
        font: style.typography.body.font,
        codeFont: style.typography.inlineCode.font,
        colors: style.colors
      ),
      images: style.images,
      imageLayout: .inline
    )
    .frame(minHeight: metrics.firstLineHeight, alignment: .center)
  }

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(style.colors.link.opacity(isExpanded ? 0.12 : 0.08))
  }

  private var cardBorder: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .strokeBorder(style.colors.link.opacity(isExpanded ? 0.42 : 0.28), lineWidth: 1)
  }

  private var detailsSeparator: some View {
    Rectangle()
      .fill(style.colors.link.opacity(0.22))
      .frame(height: 1)
      .padding(.horizontal, cardPadding)
  }

  private var detailsContent: some View {
    ScrollView(.vertical) {
      HarnessMarkdownLazyBlockStackView(
        blocks: details.blocks,
        settings: settings,
        style: style,
        spacing: style.spacing.nestedBlock
      )
      .background(HarnessMarkdownDetailsScrollTuner())
    }
    .scrollIndicators(.automatic)
    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
    .frame(maxHeight: style.spacing.detailsMaxHeight)
    .padding(cardPadding)
  }

  private var cardPadding: CGFloat {
    max(HarnessMonitorTheme.cardPadding, style.spacing.detailsContentIndent)
  }
}

private struct HarnessMarkdownDetailsScrollTuner: NSViewRepresentable {
  func makeNSView(context: Context) -> HarnessMarkdownDetailsScrollTuningView {
    HarnessMarkdownDetailsScrollTuningView()
  }

  func updateNSView(_ view: HarnessMarkdownDetailsScrollTuningView, context: Context) {
    view.tuneWhenReady()
  }
}

private final class HarnessMarkdownDetailsScrollTuningView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    tuneWhenReady()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    tuneWhenReady()
  }

  func tuneWhenReady() {
    DispatchQueue.main.async { [weak self] in
      self?.tuneScrollView()
    }
  }

  private func tuneScrollView() {
    guard let scrollView = enclosingScrollView else { return }
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.automaticallyAdjustsContentInsets = false
    let zeroInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    scrollView.contentInsets = zeroInsets
    scrollView.scrollerInsets = zeroInsets
    scrollView.usesPredominantAxisScrolling = true
    scrollView.horizontalScrollElasticity = .none
    scrollView.verticalScrollElasticity = .none
  }
}
