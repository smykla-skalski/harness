import HarnessMonitorKit
import SwiftUI

@MainActor
struct DashboardReviewsToolbarCenterpiece: View {
  let snapshot: DashboardReviewsProvenanceSnapshot

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Circle()
        .fill(snapshot.sourceTint)
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
      Text(snapshot.sourceTitle)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(snapshot.sourceTint)
        .lineLimit(1)
      Text("·")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)
      Text(snapshot.detailTitle)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .truncationMode(.tail)
    }
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
