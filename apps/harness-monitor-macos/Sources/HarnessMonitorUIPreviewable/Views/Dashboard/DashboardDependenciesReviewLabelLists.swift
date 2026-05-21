import HarnessMonitorKit
import SwiftUI

struct DashboardDependencyReviewList: View {
  let reviews: [DependencyUpdateReview]

  var body: some View {
    if reviews.isEmpty {
      Text("No reviews yet")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(reviews.enumerated()), id: \.element.id) { index, review in
          HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
            Text(review.author)
              .scaledFont(.callout)
              .foregroundStyle(HarnessMonitorTheme.ink)
            DashboardDependencyStatusPill(
              label: review.state.label,
              tint: review.state.tint,
              isQuiet: true
            )
            Spacer(minLength: 0)
          }
          .padding(.vertical, 8)
          .overlay(alignment: .bottom) {
            if index < reviews.count - 1 {
              Divider().opacity(0.45)
            }
          }
        }
      }
      .frame(maxWidth: DashboardDependenciesVisualMetrics.checksMaxWidth, alignment: .leading)
    }
  }
}

struct DashboardDependencyLabelStrip: View {
  let labels: [String]

  var body: some View {
    if labels.isEmpty {
      Text("No labels applied")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    } else {
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
          DashboardDependencyStatusPill(
            label: label,
            tint: HarnessMonitorTheme.secondaryInk,
            systemImage: "tag",
            isQuiet: true
          )
        }
      }
    }
  }
}
