import SwiftUI

struct SessionFilteredDecisionNoticeMetrics: Equatable {
  let spacing: CGFloat
  let textSpacing: CGFloat
  let padding: CGFloat
  let cornerRadius: CGFloat
  let clearButtonMinHeight: CGFloat

  init(fontScale: CGFloat) {
    let scale = min(max(fontScale, 0.85), 1.8)
    spacing = 12 * min(scale, 1.35)
    textSpacing = 4 * min(scale, 1.45)
    padding = 12 * min(scale, 1.35)
    cornerRadius = 10 * min(scale, 1.2)
    clearButtonMinHeight = scale >= 1.45 ? 44 : 0
  }
}

struct SessionFilteredDecisionNotice: View {
  let filters: SessionDecisionFilterState
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionFilteredDecisionNoticeMetrics {
    SessionFilteredDecisionNoticeMetrics(fontScale: fontScale)
  }

  var body: some View {
    HStack(alignment: .top, spacing: metrics.spacing) {
      Image(systemName: "line.3.horizontal.decrease.circle")
        .scaledFont(.body)
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: metrics.textSpacing) {
        Text("Decision hidden by current filters")
          .scaledFont(.headline)
        Text("Clear the decision filters to show this selection in the sidebar again.")
          .scaledFont(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: metrics.spacing)
      Button("Clear Filters") {
        filters.clear()
      }
      .buttonStyle(.glass)
      .tint(.secondary)
      .frame(minHeight: metrics.clearButtonMinHeight)
      .accessibilityHint("Shows the selected decision in the sidebar again.")
    }
    .padding(metrics.padding)
    .dynamicTypeSize(.xSmall ... .accessibility5)
    .background {
      RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
        .fill(.regularMaterial)
    }
    .overlay {
      RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
        .stroke(.quaternary, lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
  }
}
