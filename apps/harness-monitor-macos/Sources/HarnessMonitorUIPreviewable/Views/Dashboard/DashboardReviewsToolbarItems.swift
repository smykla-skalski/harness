import HarnessMonitorKit
import SwiftUI

@MainActor
struct DashboardReviewsToolbarCenterpiece: View {
  let snapshot: DashboardReviewsProvenanceSnapshot

  private static let padding: CGFloat = 8
  private static let cornerRadius: CGFloat = 10
  private static let width: CGFloat = 480

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(snapshot.sourceTint)
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
      Text(snapshot.sourceTitle)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(snapshot.sourceTint)
        .lineLimit(1)
      Spacer(minLength: 12)
      Text(snapshot.detailTitle)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(Self.padding)
    .frame(width: Self.width)
    .background(
      RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        .strokeBorder(
          HarnessMonitorTheme.controlBorder.opacity(0.25),
          lineWidth: 0.5
        )
    )
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
