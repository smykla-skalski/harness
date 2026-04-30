import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("ACP bridge banner announcements")
struct ContentAcpBridgeBannerAnnouncementTests {
  @Test("Announcement payload only exists when the banner is visible")
  func announcementPayloadRequiresVisibleBanner() throws {
    let state = AcpBridgeBannerState(
      firstDetectedAt: Date(timeIntervalSince1970: 100),
      retryCount: 0,
      daemonLogAvailable: true
    )

    #expect(
      ContentAcpBridgeBannerAnnouncement(
        state: state,
        isVisible: false
      ) == nil
    )

    let announcement = try #require(
      ContentAcpBridgeBannerAnnouncement(
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
      ContentAcpBridgeBannerAnnouncement(
        state: AcpBridgeBannerState(
          firstDetectedAt: firstIncidentAt,
          retryCount: 0,
          daemonLogAvailable: true
        ),
        isVisible: true
      )
    )
    let secondAnnouncement = try #require(
      ContentAcpBridgeBannerAnnouncement(
        state: AcpBridgeBannerState(
          firstDetectedAt: secondIncidentAt,
          retryCount: 1,
          daemonLogAvailable: true
        ),
        isVisible: true
      )
    )

    #expect(
      ContentAcpBridgeBannerAnnouncement.shouldAnnounce(
        firstAnnouncement,
        lastAnnouncedIncidentAt: nil
      )
    )
    #expect(
      ContentAcpBridgeBannerAnnouncement.shouldAnnounce(
        firstAnnouncement,
        lastAnnouncedIncidentAt: firstIncidentAt
      ) == false
    )
    #expect(
      ContentAcpBridgeBannerAnnouncement.shouldAnnounce(
        secondAnnouncement,
        lastAnnouncedIncidentAt: firstIncidentAt
      )
    )
  }
}
