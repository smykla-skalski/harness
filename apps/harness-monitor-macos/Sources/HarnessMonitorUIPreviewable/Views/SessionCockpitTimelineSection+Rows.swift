import HarnessMonitorKit
import SwiftUI

struct SessionTimelineEntryMarker: View {
  @ScaledMetric(relativeTo: .body)
  private var markerHeight = 18.0
  @ScaledMetric(relativeTo: .body)
  private var markerWidth = 6.0

  var body: some View {
    RoundedRectangle(cornerRadius: markerWidth / 2, style: .continuous)
      .fill(HarnessMonitorTheme.accent.opacity(0.45))
      .frame(width: markerWidth, height: markerHeight)
      .accessibilityHidden(true)
  }
}

struct SessionCockpitTimelineEntryRow: View {
  let entry: TimelineEntry
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.sectionSpacing) {
      SessionTimelineEntryMarker()
      Text(formatTimelineTimestamp(entry.recordedAt, configuration: dateTimeConfiguration))
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
      Text(entry.summary)
        .scaledFont(.system(.body, design: .rounded, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
      Text(entry.kind)
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(HarnessMonitorTheme.cardPadding)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(.primary.opacity(0.04))
    }
    .contextMenu {
      Button {
        HarnessMonitorClipboard.copy(entry.summary)
      } label: {
        Label("Copy Summary", systemImage: "doc.on.doc")
      }
      if let taskID = entry.taskId {
        Button {
          HarnessMonitorClipboard.copy(taskID)
        } label: {
          Label("Copy Task ID", systemImage: "doc.on.doc")
        }
      }
    }
  }
}

struct SessionCockpitTimelineSectionGroupRow: View {
  let section: SessionCockpitTimelineGroupSection
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      if section.showsHeader,
        let title = section.agentDisplayName
      {
        SessionCockpitTimelineAttributionHeader(
          title: title,
          capabilityTags: section.capabilityTags
        )
      }
      ForEach(section.entries) { entry in
        SessionCockpitTimelineEntryRow(
          entry: entry,
          dateTimeConfiguration: dateTimeConfiguration
        )
      }
    }
  }
}

struct SessionCockpitTimelineAttributionHeader: View {
  let title: String
  let capabilityTags: [String]

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.system(.caption, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
      if !capabilityTags.isEmpty {
        ForEach(capabilityTags.prefix(3), id: \.self) { tag in
          Text(tag)
            .scaledFont(.caption2)
            .padding(.horizontal, HarnessMonitorTheme.spacingXS)
            .padding(.vertical, 2)
            .background(
              Capsule(style: .continuous)
                .fill(HarnessMonitorTheme.secondaryInk.opacity(0.12))
            )
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

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

  private var kindWidth: CGFloat {
    let widths: [CGFloat] = [54, 66, 58]
    return widths[seed % widths.count]
  }

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.sectionSpacing) {
      shimmerBar(width: 6, height: 18, opacity: 0.18)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
      shimmerBar(width: 108)
      shimmerBar(width: summaryWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
      shimmerBar(width: kindWidth)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(HarnessMonitorTheme.cardPadding)
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
