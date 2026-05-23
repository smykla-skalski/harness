import HarnessMonitorKit
import SwiftUI

@MainActor
struct DashboardReviewsToolbarCenterpiece: View {
  let snapshot: DashboardReviewsProvenanceSnapshot

  @ScaledMetric private var dotSize: CGFloat = 6
  @ScaledMetric private var horizontalPadding: CGFloat = 14
  @ScaledMetric private var verticalPadding: CGFloat = 6
  @ScaledMetric private var contentMaxWidth: CGFloat = 480
  @ScaledMetric private var detailMinSpacing: CGFloat = 12

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(snapshot.sourceTint)
        .frame(width: dotSize, height: dotSize)
        .animation(.smooth(duration: 0.25), value: snapshot.sourceTint)
        .accessibilityHidden(true)
      Text(snapshot.sourceTitle)
        .scaledFont(.callout.weight(.semibold))
        .lineLimit(1)
      Spacer(minLength: detailMinSpacing)
      Text(snapshot.detailTitle)
        .scaledFont(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, horizontalPadding)
    .padding(.vertical, verticalPadding)
    .frame(maxWidth: contentMaxWidth)
    .glassEffect(in: Capsule())
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsToolbarProvenance)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Review data provenance")
    .accessibilityValue("\(snapshot.sourceTitle), \(snapshot.detailTitle)")
  }
}

@MainActor
struct DashboardReviewsRefreshToolbarButton: View {
  let onRefresh: () -> Void

  var body: some View {
    Button(action: onRefresh) {
      Label {
        Text("Refresh")
      } icon: {
        Image(systemName: "arrow.clockwise")
          .frame(width: 14, height: 14)
      }
    }
    .help("Refresh review data")
    .accessibilityLabel("Refresh review data")
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsRefreshButton)
    .harnessMCPButton(
      HarnessMonitorAccessibility.dashboardReviewsRefreshButton,
      label: "Refresh review data",
      hint: "Reload the Reviews list from the daemon",
      pressAction: onRefresh
    )
  }
}

@MainActor
struct DashboardReviewsInfoToolbarButton: View {
  let snapshot: DashboardReviewsProvenanceSnapshot

  @State private var isPopoverPresented = false

  var body: some View {
    Button {
      isPopoverPresented.toggle()
    } label: {
      Label {
        Text("Review Data Details")
      } icon: {
        Image(systemName: "info.circle")
          .frame(width: 14, height: 14)
      }
    }
    .help("Review data details")
    .accessibilityLabel("Show review data details")
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsToolbarInfoButton)
    .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
      DashboardReviewsProvenancePopover(snapshot: snapshot)
    }
  }
}
