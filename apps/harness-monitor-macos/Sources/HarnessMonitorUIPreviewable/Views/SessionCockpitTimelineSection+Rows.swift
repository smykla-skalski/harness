import SwiftUI

struct SessionCockpitTimelinePlaceholderRow: View {
  let seed: Int
  let shimmerPhase: CGFloat
  let showsShimmer: Bool
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private var summaryWidth: CGFloat {
    let widths: [CGFloat] = [220, 264, 198, 242]
    return widths[seed % widths.count]
  }

  private var detailWidth: CGFloat {
    let widths: [CGFloat] = [54, 66, 58]
    return widths[seed % widths.count]
  }

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.itemSpacing) {
      shimmerBar(width: SessionTimelineLayout.timeColumnWidth, height: 14)
      shimmerBar(width: 11, height: 11, opacity: 0.16)
        .clipShape(Circle())
        .frame(width: SessionTimelineLayout.railWidth)
        .padding(.top, 6)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          shimmerBar(width: 72, height: 16, opacity: 0.10)
          shimmerBar(width: 96, height: 16, opacity: 0.08)
        }
        shimmerBar(width: summaryWidth, height: 14, opacity: 0.10)
        shimmerBar(width: detailWidth, height: 12, opacity: 0.08)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HarnessMonitorTheme.cardPadding)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .background {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
          .fill(.primary.opacity(0.03))
      }
      .overlay {
        if showsShimmer {
          shimmerOverlay
            .clipShape(
              RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
            )
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityHidden(true)
  }

  private func shimmerBar(width: CGFloat, height: CGFloat = 12, opacity: Double = 0.08) -> some View
  {
    RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
      .fill(.primary.opacity(opacity))
      .frame(width: width, height: height)
  }

  private var shimmerOverlay: some View {
    GeometryReader { proxy in
      LinearGradient(
        colors: [
          .clear,
          .white.opacity(0.05),
          .white.opacity(0.22),
          .clear,
        ],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: proxy.size.width * 0.46)
      .offset(
        x: reduceMotion || showsShimmer == false
          ? 0
          : proxy.size.width * shimmerPhase
      )
      .blendMode(.plusLighter)
    }
  }
}
