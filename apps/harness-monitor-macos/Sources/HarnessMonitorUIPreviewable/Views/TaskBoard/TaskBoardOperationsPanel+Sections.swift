import SwiftUI

enum TaskBoardOperationsSectionBackground {
  case standard
  case warning
}

struct TaskBoardOperationsCard<Content: View>: View {
  let title: String
  let metrics: TaskBoardOverviewMetrics
  let footer: String?
  let background: TaskBoardOperationsSectionBackground
  let content: Content

  init(
    title: String,
    metrics: TaskBoardOverviewMetrics,
    footer: String? = nil,
    background: TaskBoardOperationsSectionBackground = .standard,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.metrics = metrics
    self.footer = footer
    self.background = background
    self.content = content()
  }

  var body: some View {
    TaskBoardOperationsFormSection(
      title: title,
      metrics: metrics,
      footer: footer,
      background: background
    ) {
      content
    }
  }
}

struct TaskBoardOperationsFormSection<Content: View>: View {
  let title: String
  let metrics: TaskBoardOverviewMetrics
  let footer: String?
  let background: TaskBoardOperationsSectionBackground
  let content: Content

  init(
    title: String,
    metrics: TaskBoardOverviewMetrics,
    footer: String? = nil,
    background: TaskBoardOperationsSectionBackground = .standard,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.metrics = metrics
    self.footer = footer
    self.background = background
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .harnessNativeFormSectionHeader()
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .padding(.leading, TaskBoardOperationsFormMetrics.sectionPadding)

      VStack(alignment: .leading, spacing: 0) {
        content
      }
      .padding(.horizontal, TaskBoardOperationsFormMetrics.sectionPadding)
      .padding(.bottom, contentBottomPadding)
      .background {
        sectionBackground
      }
      .overlay {
        sectionShape.strokeBorder(sectionStrokeColor, lineWidth: 0.5)
      }

      if let footer {
        Text(footer)
          .harnessNativeFormSectionFooter()
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, TaskBoardOperationsFormMetrics.sectionPadding)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(
      maxWidth: .infinity,
      minHeight: sectionMinHeight,
      alignment: .leading
    )
  }

  private var sectionBackground: some View {
    ZStack(alignment: .bottomTrailing) {
      sectionShape.fill(TaskBoardOperationsFormMetrics.sectionSurface)
      if background == .warning {
        sectionShape.fill(HarnessMonitorTheme.caution.opacity(0.14))
        warningBackgroundGlyph
      }
    }
    .clipShape(sectionShape)
  }

  private var warningBackgroundGlyph: some View {
    Image(systemName: "exclamationmark.triangle.fill")
      .font(.system(size: 156, weight: .black, design: .rounded))
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(HarnessMonitorTheme.caution.opacity(0.36))
      .rotationEffect(.degrees(-8))
      .offset(x: 38, y: 46)
      .accessibilityHidden(true)
      .allowsHitTesting(false)
  }

  private var sectionShape: RoundedRectangle {
    RoundedRectangle(
      cornerRadius: TaskBoardOperationsFormMetrics.sectionCornerRadius,
      style: .continuous
    )
  }

  private var sectionStrokeColor: Color {
    switch background {
    case .standard:
      HarnessMonitorTheme.controlBorder.opacity(0.24)
    case .warning:
      HarnessMonitorTheme.caution.opacity(0.34)
    }
  }

  private var contentBottomPadding: CGFloat {
    footer == nil
      ? TaskBoardOperationsFormMetrics.sectionPadding
      : 0
  }

  private var sectionMinHeight: CGFloat? {
    footer == nil ? metrics.managementPanelMinHeight : nil
  }
}
