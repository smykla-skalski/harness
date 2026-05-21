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
    VStack(alignment: .leading, spacing: style.spacing.nestedBlock) {
      summaryButton(metrics: metrics)
      if isExpanded {
        detailsContent
      }
    }
  }

  private func summaryButton(metrics: HarnessMarkdownMarkerMetrics) -> some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack(alignment: .top, spacing: metrics.gap) {
        chevron(metrics: metrics)
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
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HarnessMonitorTheme.spacingSM)
      .padding(.vertical, 6)
      .background(summaryBackground)
      .overlay(summaryBorder)
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
      .offset(y: metrics.chevronVisualYOffset)
  }

  private var summaryBackground: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(style.colors.link.opacity(isExpanded ? 0.12 : 0.08))
  }

  private var summaryBorder: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .strokeBorder(style.colors.link.opacity(isExpanded ? 0.42 : 0.28), lineWidth: 1)
  }

  private var detailsContent: some View {
    HarnessMarkdownBlockStackView(
      blocks: details.blocks,
      settings: settings,
      style: style,
      spacing: style.spacing.nestedBlock
    )
    .padding(.leading, style.spacing.detailsContentIndent)
  }
}
