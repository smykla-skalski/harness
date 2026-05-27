import CoreGraphics
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session timeline rail endpoints")
struct SessionTimelineRailEndpointsTests {
  @Test("Marker frames drive the first and last rail endpoints")
  func markerFramesDriveTheFirstAndLastRailEndpoints() {
    let endpoints = SessionTimelineRailEndpoints(
      firstRowID: "entry:first",
      lastRowID: "entry:last",
      markerFrames: [
        "entry:first": CGRect(x: 0, y: 12, width: 18, height: 18),
        "entry:last": CGRect(x: 0, y: 140, width: 18, height: 18),
      ]
    )

    #expect(endpoints.firstDotY == 21)
    #expect(endpoints.lastDotY == 149)
    #expect(endpoints.railLayout(in: 200) == (top: 21, height: 128))
  }

  @Test("Missing marker frames fall back to rail insets")
  func missingMarkerFramesFallBackToRailInsets() {
    let endpoints = SessionTimelineRailEndpoints(
      firstRowID: "entry:first",
      lastRowID: "entry:last",
      markerFrames: [:]
    )

    #expect(endpoints.firstDotY == nil)
    #expect(endpoints.lastDotY == nil)
    #expect(
      endpoints.railLayout(in: 120) == (
        top: HarnessMonitorTheme.spacingSM,
        height: 120 - HarnessMonitorTheme.spacingMD - HarnessMonitorTheme.spacingSM
      )
    )
  }
}
