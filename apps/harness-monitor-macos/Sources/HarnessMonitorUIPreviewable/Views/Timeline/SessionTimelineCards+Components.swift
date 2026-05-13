import SwiftUI

enum SessionTimelineLayout {
  static let timeColumnWidth: CGFloat = 78
  static let railWidth: CGFloat = 14
  static let markerDiameter: CGFloat = 19
  static let markerCoreDiameter: CGFloat = 11
  static let railLineOffset =
    timeColumnWidth + HarnessMonitorTheme.itemSpacing + (railWidth / 2)
}

extension VerticalAlignment {
  enum SessionTimelineMarkerCenter: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
      context[VerticalAlignment.center]
    }
  }

  static let sessionTimelineMarkerCenter = VerticalAlignment(
    SessionTimelineMarkerCenter.self
  )

  enum SessionTimelineFirstLineCenter: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
      context[VerticalAlignment.center]
    }
  }

  static let sessionTimelineFirstLineCenter = VerticalAlignment(
    SessionTimelineFirstLineCenter.self
  )
}

struct SessionTimelineRailBackground: View {
  let endpoints: SessionTimelineRailEndpoints

  init(endpoints: SessionTimelineRailEndpoints = .init()) {
    self.endpoints = endpoints
  }

  var body: some View {
    GeometryReader { proxy in
      let layout = endpoints.railLayout(in: proxy.size.height)
      Rectangle()
        .fill(HarnessMonitorTheme.controlBorder.opacity(0.55))
        .frame(width: 2, height: layout.height)
        .offset(
          x: SessionTimelineLayout.railLineOffset - 1,
          y: layout.top
        )
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

struct SessionTimelineDot: View {
  let tint: Color

  var body: some View {
    ZStack {
      Circle()
        .fill(.background)
        .frame(
          width: SessionTimelineLayout.markerDiameter,
          height: SessionTimelineLayout.markerDiameter
        )
      Circle()
        .fill(tint)
        .frame(
          width: SessionTimelineLayout.markerCoreDiameter,
          height: SessionTimelineLayout.markerCoreDiameter
        )
    }
    .frame(width: SessionTimelineLayout.railWidth, alignment: .center)
    .shadow(color: tint.opacity(0.4), radius: 8)
    .accessibilityHidden(true)
  }
}

struct SessionTimelineCardBackground: View {
  let tint: Color

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
  }

  var body: some View {
    shape
      .fill(tint.opacity(0.08))
      .overlay {
        shape
          .strokeBorder(tint.opacity(0.35), lineWidth: 1)
      }
  }
}
