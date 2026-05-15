import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("ACP bridge banner announcements")
struct AcpBridgeBannerAnnouncementTests {
  @Test("Announcement payload only exists when the banner is visible")
  func announcementPayloadRequiresVisibleBanner() throws {
    let state = AcpBridgeBannerState(
      firstDetectedAt: Date(timeIntervalSince1970: 100),
      retryCount: 0,
      daemonLogAvailable: true
    )

    #expect(
      AcpBridgeBannerAnnouncement(
        state: state,
        isVisible: false
      ) == nil
    )

    let announcement = try #require(
      AcpBridgeBannerAnnouncement(
        state: state,
        isVisible: true
      )
    )

    #expect(announcement.incidentID == state.firstDetectedAt)
    #expect(announcement.message.contains("ACP bridge outage."))
    #expect(announcement.message.contains(AcpBridgeBannerState.blastRadiusText))
  }

  @Test("Announcement helper only fires once per incident")
  func announcementHelperOnlyFiresOncePerIncident() throws {
    let firstIncidentAt = Date(timeIntervalSince1970: 100)
    let secondIncidentAt = Date(timeIntervalSince1970: 200)
    let firstAnnouncement = try #require(
      AcpBridgeBannerAnnouncement(
        state: AcpBridgeBannerState(
          firstDetectedAt: firstIncidentAt,
          retryCount: 0,
          daemonLogAvailable: true
        ),
        isVisible: true
      )
    )
    let secondAnnouncement = try #require(
      AcpBridgeBannerAnnouncement(
        state: AcpBridgeBannerState(
          firstDetectedAt: secondIncidentAt,
          retryCount: 1,
          daemonLogAvailable: true
        ),
        isVisible: true
      )
    )

    #expect(
      AcpBridgeBannerAnnouncement.shouldAnnounce(
        firstAnnouncement,
        lastAnnouncedIncidentAt: nil
      )
    )
    #expect(
      AcpBridgeBannerAnnouncement.shouldAnnounce(
        firstAnnouncement,
        lastAnnouncedIncidentAt: firstIncidentAt
      ) == false
    )
    #expect(
      AcpBridgeBannerAnnouncement.shouldAnnounce(
        secondAnnouncement,
        lastAnnouncedIncidentAt: firstIncidentAt
      )
    )
  }
}
